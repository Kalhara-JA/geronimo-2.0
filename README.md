# Google Drive Document Vectorization Service – Design & Reasoning

## 1. Purpose & Motivation

The service ingests Google Docs stored in a specific Drive folder into a vector store so that other services (chat‑bots, semantic search, RAG pipelines) can retrieve relevant passages quickly. It supports two operating modes:

* **Initial bootstrap** – process everything once (`POST /vectorize/init`).
* **Incremental updates** – process only the documents that changed since the last run (`POST /vectorize/changes`).

Keeping the vectors fresh without re‑processing all documents saves cost and time while guaranteeing that queries see up‑to‑date content.

---

## 2. High‑Level Architecture

| Layer                      | Responsibility                                     | Key Components                                                        |
| -------------------------- | -------------------------------------------------- | --------------------------------------------------------------------- |
| **Entry points**           | Human‑triggered or clock‑triggered invocations     | HTTP service (`/vectorize`), scheduled `task:Job` (commented for now) |
| **Workflow orchestration** | Pull documents → transform → embed → store vectors | `processDocuments()` & `processSingleDocument()`                      |
| **Persistence**            | Idempotency & metadata                             | PostgreSQL tables `fileprocessingstatuses`, `tokens`                  |
| **External APIs**          | Content & embedding providers                      | Google Drive SDK, Azure OpenAI embeddings                             |
| **Vector store**           | Fast ANN retrieval                                 | `vectorStore` abstraction                                             |

The diagram below shows the call sequence for *incremental updates* (arrows are function calls):

```
/vectorize/changes  ─▶ retrieveUpdatedDocuments ─▶ processDocuments ─▶ processSingleDocument
                                              ▲                      │
                                              │                      ├─► chunkMarkdownText
                                              │                      ├─► getEmbeddingsBatched
                                              │                      └─► addVectorEntry / deleteExistingVectors
```

---

## 3. Design Decisions & Rationale

| Decision                                       | Reason                                                                                                                         |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Ballerina** for implementation               | Native HTTP, scheduling, and typed JSON make cloud‑native integration concise.                                                 |
| **Separate init/changes endpoints**            | Allows a *full rebuild* without resetting tokens, and a *cheap delta* path for daily cron jobs.                                |
| **Idempotent DB layer** (`upsertFileStatus`)   | Prevents double work when the same file appears in multiple runs or retries.                                                   |
| **Skip non‑Google‑Docs & trashed items early** | Saves bandwidth and avoids noisy vectors.                                                                                      |
| **Batch embeddings (100 chunks/request)**      | Reduces round‑trips while staying under Azure OpenAI payload limits.                                                           |
| **Section‑aware chunking with word overlap**   | Preserves heading context and minimises boundary artefacts for downstream LLMs.                                                |
| **Export as Markdown**                         | Google Docs are exported as Markdown to retain headings/lists while stripping style, giving the chunker clear structural cues. |

---

## 4. The Chunking Mechanism in Detail

The goal is to split each **Markdown document exported from Google Docs** into semantic
chunks that are:

* **≤ ****`MAX_TOKENS`**** (400) words** – keeps embeddings within model limits.
* **Overlapping by ****`OVERLAP_TOKENS`**** (50) words** – ensures that information straddling a boundary is present in at least one chunk.
* **Annotated with heading context** – so a match can be surfaced with its logical section.

### 4.1 Section Detection (`gatherSections`)

`gatherSections()` scans the Markdown line‑by‑line. When it sees a heading (`#`, `##`, …, `######`) it starts a new *section* record, capturing:

* `headingLevel` (1 ↔ 6)
* `headingText` (the title without `#`)
* `contentLines[]` – the raw lines until the next heading

The first section is a synthetic **Preamble** (for text before the first heading).

### 4.2 Sub‑Chunk Creation (`createSubChunks`)

Inside each section we iterate over paragraphs, building a rolling buffer of words:

1. **If adding the next paragraph would exceed the 400‑word limit**:

   * Flush the current buffer as a chunk.
   * Copy the last 50 words into a new buffer (the *overlap slice*).
2. Always append the paragraph words to the buffer.
3. After the loop, flush any remaining buffer.

The chunk is stored as a `MarkdownChunk` with the inherited metadata and a monotonically increasing `chunkIndex`.

### 4.3 Illustrative Example

Assume this tiny Markdown (each line shown with its word count):

```
# Project Overview                              (2)
Intro text describing the project… (10)
Intro (continued)… (20)

## Requirements                                 (1)
The system SHALL… (120)
More details… (250)

## Architecture                                 (1)
High‑level view… (300)
```

*Section 1* (`# Project Overview`) contains **32** words → **1 chunk**.

*Section 2* (`## Requirements`) contains **371** words. With a 400‑word limit it also fits in **1 chunk** (no split).

*Section 3* (`## Architecture`) contains **300** words but because the previous chunk already used 371 words, adding it would exceed 400. Therefore a split occurs at the section boundary. Outcome:

| Chunk # | Heading                | Words         | Overlap?                            |
| ------- | ---------------------- | ------------- | ----------------------------------- |
|  0      | Project Overview       |  32           | –                                   |
|  1      | Requirements           |  371          | –                                   |
|  2      | ⋯Architecture (part 1) |  350          | –                                   |
|  3      | ⋯Architecture (part 2) |  50 (overlap) | ✓ (copies last 50 words of chunk 2) |

> After embedding, chunks 2 & 3 share 50 common words so a query touching their boundary retrieves consistent context.

---

### 4.4 Why this chunking strategy works well for RAG

Our chosen approach is tuned specifically to the behaviour of modern RAG pipelines that use an **Embed → ANN search → LLM synthesis** loop:

* **Balanced context vs. noise** – 400 words (≈ 600–700 tokens) is large enough to capture a coherent thought (often a full requirement or subsection) yet small enough to keep hallucination risk low when the LLM concatenates multiple chunks.
* **Section‑aware keys** – By inheriting the Markdown heading we preserve a *semantic anchor* that boosts reranking models: a chunk titled "## Performance Requirements" naturally scores higher for queries about latency.
* **Overlap for boundary recall** – The 50‑word tail‑head overlap avoids *lost sentences* when a user asks about content that straddles a split point. Without it, the ANN index might miss the relevant fragment entirely, hurting recall.
* **Fixed upper bound** – RAG frameworks frequently concatenate the top‑k chunks into a single prompt. Knowing the maximum chunk size allows deterministic prompt budgeting and prevents "Context length exceeded" errors.

### 4.5 Alternative strategies & optimisation levers

Although the current algorithm is a solid default, there are scenarios where a different strategy may yield better quality or cost efficiency:

| Technique                                                     | How it works                                                                                | Pros                                                                        | Cons                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **Token‑aware splitting** (`tiktoken`, `ollama_tokenizer`, …) | Measure *model* tokens instead of words when counting length.                               | 1:1 alignment with true embedding limit; avoids edge cases with long words. | Slightly slower; another dependency.                                   |
| **Semantic/TextRank segmentation**                            | Use sentence embeddings or TextRank to break on topic shifts rather than hard limits.       | Chunks are thematically cohesive; higher relevance.                         | Variable sizes complicate prompt packing; extra compute at build time. |
| **Recursive overlap** (LLAMA‑Index style)                     | Build a hierarchy (document → section → paragraph) and search coarse‑to‑fine.               | Lets you retrieve broader context first; fewer vectors overall.             | Implementation complexity; two‑stage retrieval latency.                |
| **Dynamic window size**                                       | Tune `MAX_TOKENS` per document based on total length (e.g. smaller windows for short docs). | Reduces over‑chunking tiny files; cuts embedding cost.                      | Need heuristics; rare edge cases where recall suffers.                 |
| **No overlap + window expansion at query time**               | Store non‑overlapping chunks and, if a hit is near the end, fetch its neighbour.            | Halves vector count vs. 50‑token overlap.                                   | Requires post‑processing logic; more round‑trips to DB/vector store.   |

> **Rule of thumb:** if recall on retrieval is already ≥ 95 % for your QA benchmarks, prioritise **cost optimisations**; otherwise, test a semantic‑aware splitter before increasing overlap.

---

## 5. Scalability & Safety for Large Corpora

The pipeline is engineered so it **continues to behave predictably when the corpus grows from dozens to tens of thousands of documents**:

* **Memory‑efficient streaming** – Drive files are consumed via a `stream<drive:File>` iterator, so only one file’s metadata lives in memory at any moment.
* **Chunk‑level granularity** – Even a 300‑page doc is processed incrementally; partial progress survives restarts because `fileprocessingstatuses` records the last successful state.
* **Batched I/O** – Embeddings are requested in blocks of 100 chunks (≈60 KB payload) to stay under Azure’s 128 KB limit while achieving \~10× fewer HTTP calls compared to per‑chunk requests.
* **Back‑pressure friendly** – The 1‑second `runtime:sleep()` between batches prevents exceeding token-per‑minute quotas; it can be dynamically tuned for larger quotas.
* **Upsert‑based idempotency** – `upsertFileStatus()` ensures that re‑processing or retrying a file does not duplicate vectors or log spam—crucial when thousands of documents are processed by a cron job each night.
* **Token‑gated delta sync** – Incremental endpoint only fetches items whose `modifiedTime` is newer than the last token, so O(n) work is avoided when nothing changed.
* **Parallelisation ready** – Because each `processSingleDocument` call is self‑contained, the outer loop can later be sharded across workers or executed in Ballerina `worker` pools without altering business logic.

## 6. Data Sanitisation & Integrity

Large heterogeneous corpora often include malformed Unicode, control characters, or corrupt metadata. Two utility helpers keep the pipeline safe:

| Function                                  | What it does                                                                                                                  | Why it matters                                                                                                                   |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `sanitizeJson(json input)`                | Recursively traverses primitives, arrays, and maps; removes invalid backslash escapes, converts `Inf`/`-Inf`/`NaN` to `null`. | Guarantees that the JSON handed to the vector store or DB is **round‑trip serialisable** and won’t explode during JSONB parsing. |
| `sanitizeMetadata(map<json> rawMetadata)` | Calls the above and clones the result into a typed `map<json>`.                                                               | Prevents injection of unexpected datatypes (e.g., XML nodes) that could crash downstream analytics.                              |

**Result:** Even if a Google Doc contains exotic characters or the Drive API returns partial data, the service fails gracefully (logs + `STATUS_ERROR`) instead of poisoning the vector index or breaking every future retrieval.

---

## 7. Embedding & Vector Storage

* **`getEmbeddingsBatched`** keeps the service within rate limits by inserting a 1‑second `runtime:sleep` between calls.(Azure OpenAI **text‑embedding‑small‑3** model for embedding generation)
* **`addVectorEntry`** writes each embedding plus a JSON metadata object (`fileId`, `heading`, `chunkIndex`, …) so the search layer can reconstruct references.
* **Existing vectors** for the same doc are deleted *after* the new vectors succeed, ensuring zero downtime.

---

## 8. Token Management for Incremental Updates

Google Drive’s *start page token* is stored in a dedicated table. `retrieveUpdatedDocuments` converts that token’s timestamp into Drive’s `"modifiedTime > …"` query so the delta endpoint only pulls what actually changed.

The update algorithm:

1. Read **row 2** (current token).
2. Process deltas.
3. Move **row 2** to **row 1** (archive) and insert the new token into **row 2**.

This two‑row swap guarantees we never lose the last successful token even if the write of the new one fails.

---

## 9. Error Handling & Observability

* **Structured logs** at `INFO`, `DEBUG`, `WARN`, `ERROR` with consistent prefixes make tracing easy in a log aggregator.
* All retryable failures return an `error` that bubbles to the HTTP caller or the scheduler, making alerts straightforward.
* File‑level processing outcome is persisted so reruns can skip successes and only revisit failures.

---

## 10. Summary

The service provides a robust, resumable pipeline that turns Google Docs into semantically searchable vector representations. The chunking algorithm balances model limits with retrieval quality by being section‑aware and overlapping boundary words. Together with idempotent state tracking and a clean separation between initial and delta runs, it lays a solid foundation for production‑grade RAG systems.
