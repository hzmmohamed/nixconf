{...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    python3Packages = pkgs.python313Packages;
    # Pre-fetched faster-whisper-tiny model (Systran/faster-whisper-tiny on HuggingFace)
    whisperTinyModel = pkgs.stdenv.mkDerivation {
      pname = "faster-whisper-tiny-model";
      version = "1.0";
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out
        cp ${pkgs.fetchurl {
          url = "https://huggingface.co/Systran/faster-whisper-tiny/resolve/main/model.bin";
          hash = "sha256-3LdsZYb8Bsvaxt0h8Uz9EpzEzdnc4Zv0/6YuWcvm5tE=";
        }} $out/model.bin
        cp ${pkgs.fetchurl {
          url = "https://huggingface.co/Systran/faster-whisper-tiny/resolve/main/config.json";
          hash = "sha256-pzoozf4cQ8zHIC+jM9H4nCAkdycUB66afxmvpSA5ysg=";
        }} $out/config.json
        cp ${pkgs.fetchurl {
          url = "https://huggingface.co/Systran/faster-whisper-tiny/resolve/main/tokenizer.json";
          hash = "sha256-+3tjGR6bsEUILHn9dCoxBqEsmVE6sw30oNR/pstv0Ks=";
        }} $out/tokenizer.json
        cp ${pkgs.fetchurl {
          url = "https://huggingface.co/Systran/faster-whisper-tiny/resolve/main/vocabulary.txt";
          hash = "sha256-NM4/4cUEECez+NQpEicJk/mG28S7NM8n+VHjSh5FORM=";
        }} $out/vocabulary.txt
      '';
    };
  in {
    packages.whisper-tiny-model = whisperTinyModel;

    packages.whisper-live = python3Packages.buildPythonPackage {
      pname = "whisper-live";
      version = "0.8.0";
      format = "setuptools";

      src = pkgs.fetchFromGitHub {
        owner = "collabora";
        repo = "WhisperLive";
        rev = "v0.8.0";
        hash = "sha256-/JOPgIsHfA/aksM86BRmKKrBCPRY1tUOmR9PAv7zoxU=";
      };

      propagatedBuildInputs = with python3Packages; [
        faster-whisper
        websockets
        websocket-client
        pyaudio
        scipy
        soundfile
        numpy
        numba
        librosa
      ];

      # Remove backends and deps we don't use (openvino, torch, onnxruntime)
      postPatch = ''
        sed -i '/openvino/d' setup.py
        sed -i '/torch/d' setup.py
        sed -i '/torchaudio/d' setup.py
        sed -i '/onnxruntime/d' setup.py
        sed -i '/openai-whisper/d' setup.py
        sed -i '/kaldialign/d' setup.py
        sed -i '/optimum/d' setup.py
        sed -i '/tokenizers/d' setup.py

        # Make torch import optional (only used for cuda detection)
        for f in whisper_live/server.py whisper_live/vad.py whisper_live/backend/faster_whisper_backend.py whisper_live/backend/translation_backend.py; do
          sed -i 's/^import torch$/try:\n    import torch\nexcept ImportError:\n    torch = None/' "$f"
          sed -i 's/torch\.cuda\.is_available()/getattr(torch, "cuda", None) is not None and torch.cuda.is_available()/' "$f"
        done
      '';

      pythonRelaxDeps = [
        "numpy"
        "faster-whisper"
      ];

      doCheck = false;

      meta = {
        description = "A nearly-live implementation of OpenAI's Whisper";
        homepage = "https://github.com/collabora/WhisperLive";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
      };
    };
  };
}
