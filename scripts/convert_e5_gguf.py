"""Convert intfloat/multilingual-e5-small (Microsoft, MIT) to GGUF for llama.cpp.

Usage: python -s -E scripts/convert_e5_gguf.py <llama.cpp dir> <HF model dir> <out.gguf> [q8_0|f16]

The model is a BERT encoder (absolute positions from 0) with the XLM-RoBERTa
SentencePiece vocabulary. llama.cpp b12182's BertModel converter only knows
WordPiece vocabularies and stops at "BPE pre-tokenizer was not recognized", so
this wrapper swaps in the converter's own XLM-RoBERTa SentencePiece vocabulary
writer and leaves the rest (tensors, mean pooling from 1_Pooling) unchanged.
The result is checked against the PyTorch reference by
rag_handoff/reference/verify_e5_gguf.py.
"""
import pathlib
import sys

llama, model, out = (pathlib.Path(arg) for arg in sys.argv[1:4])
outtype = sys.argv[4] if len(sys.argv) > 4 else "q8_0"
sys.path.insert(0, str(llama))
sys.path.insert(1, str(llama / "gguf-py"))

from conversion import bert  # noqa: E402

# Vocabulary only: XLMRobertaModel would also shift position embeddings by
# pad_token_id + 1, which is wrong for this BertModel checkpoint.
bert.BertModel.set_vocab = bert.BertModel._xlmroberta_set_vocab

import convert_hf_to_gguf  # noqa: E402

sys.argv = ["convert_hf_to_gguf.py", str(model), "--outtype", outtype, "--outfile", str(out)]
convert_hf_to_gguf.main()
