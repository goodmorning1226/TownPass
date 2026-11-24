"""Paths outside the repository for the portal assistant's Python scripts
(portal_assistant/docs/TEAM_LOCAL_SETUP.md section 3.1).

  TOWNPASS_PORTAL_ASSISTANT_WORK      the work folder: models, evaluation data, native sources, study outputs
  TOWNPASS_PORTAL_ASSISTANT_MSYS_BIN  MSYS2's bin folder (DLLs of a host whisper.cpp built with MSYS2 gcc);
                                      unset: the DLLs are found on PATH

Nothing here fails at import time: a script that only imports another script's tables
(serve_assistant_models.py imports build_model_manifest.FILES) still loads without the
variables. work_dir() stops with a clear message when a path is actually needed.
"""
import os
import pathlib

WORK_VAR = "TOWNPASS_PORTAL_ASSISTANT_WORK"
MSYS_VAR = "TOWNPASS_PORTAL_ASSISTANT_MSYS_BIN"
# Stands in for the work folder in module-level paths (work_path) while the variable is unset.
UNSET = pathlib.Path(f"%{WORK_VAR}%")


def work_dir_or_none():
    """The work folder, or None when TOWNPASS_PORTAL_ASSISTANT_WORK is not set (for optional data)."""
    value = os.environ.get(WORK_VAR, "").strip()
    return pathlib.Path(value) if value else None


def work_dir():
    """The work folder; stops the script with a clear message when the variable is not set."""
    folder = work_dir_or_none()
    if folder is None:
        raise SystemExit(f"{WORK_VAR} is not set. Set it to the work folder outside the repository "
                         "(models, evaluation data; portal_assistant/docs/TEAM_LOCAL_SETUP.md section 3.1).")
    return folder


def work_path(*parts):
    """A path under the work folder for module-level constants: never fails at import, but points
    under a placeholder while the variable is unset, so call work_dir() before using it."""
    return (work_dir_or_none() or UNSET).joinpath(*parts)


def msys_bin():
    """MSYS2's bin folder, or "" when TOWNPASS_PORTAL_ASSISTANT_MSYS_BIN is not set."""
    return os.environ.get(MSYS_VAR, "").strip()


def path_with_msys():
    """PATH with MSYS2's bin folder first when it is set (for host whisper.cpp / llama.cpp tools)."""
    return os.pathsep.join(part for part in (msys_bin(), os.environ.get("PATH", "")) if part)
