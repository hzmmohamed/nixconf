{
  # Default applications (xdg-open / gio / file-manager double-click).
  # Without this, the first app that claims a type wins — e.g. images opened
  # in Chromium.
  flake.nixosModules.mime-defaults = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;

    browser = "firefox.desktop";
    imageViewer = "org.gnome.Loupe.desktop";
    pdfViewer = "org.pwmt.zathura-pdf-mupdf.desktop";
    fileManager = "thunar.desktop";
    textEditor = "codium.desktop";
    mediaPlayer = "mpv.desktop";

    assoc = app: types: lib.genAttrs types (_: [app]);

    imageTypes = [
      "image/apng"
      "image/avif"
      "image/bmp"
      "image/gif"
      "image/heic"
      "image/jpeg"
      "image/jxl"
      "image/png"
      "image/svg+xml"
      "image/tiff"
      "image/vnd.microsoft.icon"
      "image/webp"
      "image/x-portable-pixmap"
      "image/x-tga"
    ];

    textTypes = [
      "text/plain"
      "text/markdown"
      "text/x-markdown"
      "text/csv"
      "text/x-log"
      "text/x-python"
      "text/x-csrc"
      "text/x-chdr"
      "text/x-c++src"
      "text/x-rust"
      "text/x-go"
      "text/x-nix"
      "text/x-shellscript"
      "application/x-shellscript"
      "application/json"
      "application/toml"
      "application/x-yaml"
      "application/yaml"
      "application/xml"
      "text/xml"
    ];

    mediaTypes = [
      "video/mp4"
      "video/x-matroska"
      "video/webm"
      "video/quicktime"
      "video/x-msvideo"
      "video/mpeg"
      "video/ogg"
      "video/x-flv"
      "video/3gpp"
      "audio/mpeg"
      "audio/mp4"
      "audio/x-m4a"
      "audio/flac"
      "audio/x-flac"
      "audio/ogg"
      "audio/opus"
      "audio/wav"
      "audio/x-wav"
      "audio/aac"
      "audio/webm"
    ];

    webTypes = [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
      "x-scheme-handler/about"
      "x-scheme-handler/unknown"
    ];
  in {
    # The image and PDF viewers are owned here so the defaults always resolve.
    # (Loupe: GTK4/libadwaita, follows the light/dark color-scheme set by
    # darkman, broad format support incl. AVIF/HEIC/JXL/SVG via glycin.)
    environment.systemPackages = [
      pkgs.loupe
      pkgs.zathura
    ];

    home-manager.users.${user}.xdg.mimeApps = {
      enable = true;
      defaultApplications =
        assoc imageViewer imageTypes
        // assoc textEditor textTypes
        // assoc mediaPlayer mediaTypes
        // assoc browser webTypes
        // {
          "application/pdf" = [pdfViewer];
          "application/epub+zip" = [pdfViewer];
          "inode/directory" = [fileManager];
          "x-scheme-handler/mailto" = ["thunderbird.desktop"];
          # Carried over from the previous hand-managed mimeapps.list
          "x-scheme-handler/discord" = ["vesktop.desktop"];
          "x-scheme-handler/claude-cli" = ["claude-code-url-handler.desktop"];
        };
    };
  };
}
