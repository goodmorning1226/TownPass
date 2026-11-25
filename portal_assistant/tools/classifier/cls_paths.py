"""Paths for the decision-classifier training scripts.

The repository (and the backend, catalogue assets and FAQ tuning set in it) is found from this
file's location: portal_assistant/tools/classifier/ -> repository = parents[3]. Everything that is
not in the repository - training data, models, caches, results, llama.cpp binaries - comes from
environment variables (or the scripts' command-line arguments, which override them):

  TOWNPASS_CLASSIFIER_WORK     the work directory holding data/, models/, cache/, results/, hf/
  TOWNPASS_CLASSIFIER_WRITTEN  the hand-written v2 sentences (written.py; default
                               <work>/data/v2/written.py). Training data: never in the repository.
  TOWNPASS_LLAMA_SERVER        llama-server executable (CPU build; e5 and the classifier)
  TOWNPASS_LLAMA_SERVER_GPU    llama-server executable for the decision LLM (Vulkan build)
  TOWNPASS_E5_GGUF             multilingual-e5-small q8_0 GGUF (embedding server)
  TOWNPASS_CLASSIFIER_GGUF     the classifier GGUF to evaluate (run_setup.py --classifier)
  TOWNPASS_MINISTRAL_GGUF, TOWNPASS_GEMMA_GGUF   decision LLMs (run_setup.py --llm)
"""
import os
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
PORTAL = REPO / "portal_assistant"
BACKEND = PORTAL / "backend"
ASSETS = PORTAL / "app" / "assets" / "assistant"
TUNING = PORTAL / "rag_handoff" / "tuning"

WORK_ENV = "TOWNPASS_CLASSIFIER_WORK"
WRITTEN_ENV = "TOWNPASS_CLASSIFIER_WRITTEN"
LLAMA_SERVER_ENV = "TOWNPASS_LLAMA_SERVER"
LLAMA_SERVER_GPU_ENV = "TOWNPASS_LLAMA_SERVER_GPU"
E5_GGUF_ENV = "TOWNPASS_E5_GGUF"
CLASSIFIER_GGUF_ENV = "TOWNPASS_CLASSIFIER_GGUF"
LLM_GGUF_ENV = {"ministral": "TOWNPASS_MINISTRAL_GGUF", "gemma": "TOWNPASS_GEMMA_GGUF"}


def add_backend():
    """Put the repository's backend first on sys.path (classifier, faq, registry, ... modules)."""
    if str(BACKEND) not in sys.path:
        sys.path.insert(0, str(BACKEND))


def set_work(value):
    """A --work argument: overrides TOWNPASS_CLASSIFIER_WORK for this process."""
    if value:
        os.environ[WORK_ENV] = str(pathlib.Path(value).resolve())


def work_dir():
    value = os.environ.get(WORK_ENV)
    if not value:
        raise SystemExit(f"set {WORK_ENV} (or pass --work) to the work directory that holds "
                         "data/, models/, cache/ and results/ (outside the repository)")
    return pathlib.Path(value)


def v2_dir():
    return work_dir() / "data" / "v2"


def written_file(value=None):
    value = value or os.environ.get(WRITTEN_ENV)
    return pathlib.Path(value) if value else v2_dir() / "written.py"


def required(value, env, what, argument=None):
    """An executable or model path: the argument, else the environment variable, else stop."""
    value = value or os.environ.get(env)
    if not value:
        raise SystemExit(f"set {env}" + (f" (or pass {argument})" if argument else "") + f" to {what}")
    return value


def work_argument(parser):
    parser.add_argument("--work", help=f"work directory (data/, models/, cache/, results/); "
                                       f"default: ${WORK_ENV}")
