# Dictation model pins: flake-level data, read as `self.dictationModels pkgs`
# by every consumer of the same models, so the laptops (dictation feature) and
# the phone (dictation-server's phone profile, which serves the Parakeet files
# and their hashes) never drift apart.
#
#   parakeet         Parakeet TDT 0.6B v2, int8 ONNX (sherpa-onnx export,
#                    model_type nemo_transducer, English): a directory with
#                    encoder/decoder/joiner .int8.onnx + tokens.txt (~640 MB)
#   parakeetArchive  its upstream tarball ({url; hash;}), the phone's
#                    fallback download
#   whisperSmall     Whisper small q5_1 (GGML, multilingual offline, 190 MB)
#   sileroVadOnnx    Silero VAD v6.2 (ONNX, 2.3 MB) for client-side segmenting
{...}: {
  flake.dictationModels = pkgs: rec {
    parakeetArchive = {
      url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2";
      hash = "sha256-b8RCa1SqVJoAGbinW43qWRZOcXkKN6xWoEWtV/kV9xQ=";
    };

    parakeet = pkgs.stdenvNoCC.mkDerivation {
      pname = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
      version = "2025-05";
      src = pkgs.fetchurl parakeetArchive;
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        mkdir -p $out
        cp encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt $out/
      '';
    };

    whisperSmall = pkgs.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin";
      hash = "sha256-roXkqTXXpWe9EC/lWvwWu1lb22GOEbL8dZG8CBIEEbs=";
    };

    sileroVadOnnx = pkgs.fetchurl {
      name = "silero-vad-v6.2.3.onnx";
      url = "https://github.com/snakers4/silero-vad/raw/v6.2.3/src/silero_vad/data/silero_vad.onnx";
      hash = "sha256-GhU6IvRQnikqlOZ9b5uF6N6yW0mIaCt+F0xlJ52HiOM=";
    };
  };
}
