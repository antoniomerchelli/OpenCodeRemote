#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="$PROJECT_DIR/Sources/OpenCodeRemoteApp/Resources/Assets.xcassets"

echo "==> OpenCode Remote — Asset Catalog Generator"
echo ""

# ─── 1. Create asset catalog structure ─────────────────────────────────────

mkdir -p "$ASSETS_DIR"

# ─── 2. Contents.json (root) ────────────────────────────────────────────────

cat > "$ASSETS_DIR/Contents.json" << 'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# ─── 3. AccentColor ─────────────────────────────────────────────────────────

mkdir -p "$ASSETS_DIR/AccentColor.colorset"
cat > "$ASSETS_DIR/AccentColor.colorset/Contents.json" << 'EOF'
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "1.000",
          "green" : "0.500",
          "red" : "0.200"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "1.000",
          "green" : "0.600",
          "red" : "0.400"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# ─── 4. Theme Colors ────────────────────────────────────────────────────────

# Nota: bash 3.2 (default di macOS) NON supporta gli array associativi (declare -A):
# usiamo coppie "nome=r,g,b" in stringhe + helper get_color.

THEME_COLORS_LIGHT="backgroundPrimary=1,1,1 backgroundSecondary=0.95,0.95,0.97 backgroundTertiary=0.90,0.90,0.92 textPrimary=0.05,0.05,0.07 textSecondary=0.40,0.40,0.45 textTertiary=0.60,0.60,0.65"
THEME_COLORS_DARK="backgroundPrimary=0.05,0.05,0.07 backgroundSecondary=0.10,0.10,0.13 backgroundTertiary=0.15,0.15,0.18 textPrimary=0.95,0.95,0.97 textSecondary=0.70,0.70,0.75 textTertiary=0.50,0.50,0.55"

COLOR_NAMES="backgroundPrimary backgroundSecondary backgroundTertiary textPrimary textSecondary textTertiary"

# get_color <stringa colori> <nome> <componente 1|2|3>
get_color() {
    local pair value
    for pair in $1; do
        case "$pair" in
            "$2="*) value="${pair#*=}" ;;
        esac
    done
    echo "$value" | cut -d, -f"$3"
}

for COLOR_NAME in $COLOR_NAMES; do
    COLOR_DIR="$ASSETS_DIR/$COLOR_NAME.colorset"
    mkdir -p "$COLOR_DIR"

    LR=$(get_color "$THEME_COLORS_LIGHT" "$COLOR_NAME" 1)
    LG=$(get_color "$THEME_COLORS_LIGHT" "$COLOR_NAME" 2)
    LB=$(get_color "$THEME_COLORS_LIGHT" "$COLOR_NAME" 3)
    DR=$(get_color "$THEME_COLORS_DARK" "$COLOR_NAME" 1)
    DG=$(get_color "$THEME_COLORS_DARK" "$COLOR_NAME" 2)
    DB=$(get_color "$THEME_COLORS_DARK" "$COLOR_NAME" 3)

    cat > "$COLOR_DIR/Contents.json" << COLOREOF
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "${LB}",
          "green" : "${LG}",
          "red" : "${LR}"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "${DB}",
          "green" : "${DG}",
          "red" : "${DR}"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
COLOREOF
done

# ─── 5. AppIcon ─────────────────────────────────────────────────────────────

mkdir -p "$ASSETS_DIR/AppIcon.appiconset"
ICON_PNG="$ASSETS_DIR/AppIcon.appiconset/icon-1024.png"

cat > "$ASSETS_DIR/AppIcon.appiconset/Contents.json" << 'ICONEOF'
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
ICONEOF

# Genera un'icona base 1024x1024 (sfondo scuro + cerchio accent) se il PNG
# non esiste già: senza di esso il build fallisce.
if [ ! -f "$ICON_PNG" ] && command -v swift >/dev/null 2>&1; then
    cat > /tmp/gen_icon.swift << 'SWIFTEOF'
import AppKit
// NSBitmapImageRep esplicito a 1024x1024: NSImage.lockFocus disegna a 2x su Retina.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = ctx
NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.078, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let circle = NSBezierPath(ovalIn: NSRect(x: 302, y: 302, width: 420, height: 420))
NSColor(calibratedRed: 0.678, green: 0.776, blue: 1.0, alpha: 1).setFill()
circle.fill()
ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFTEOF
    swift /tmp/gen_icon.swift "$ICON_PNG" && rm -f /tmp/gen_icon.swift
fi

echo "[+] Asset catalog created at: $ASSETS_DIR"
echo "    Colors:"
for COLOR_NAME in $COLOR_NAMES; do
    echo "      - $COLOR_NAME"
done
echo "      - AccentColor"
if [ -f "$ICON_PNG" ]; then
    echo "    AppIcon: icon-1024.png generata (placeholder: sostituire con l'icona definitiva)"
else
    echo "    AppIcon placeholder (aggiungere icon-1024.png manualmente)"
fi
echo ""
echo "    Next step: open the project in Xcode and add this folder"
echo "    to the OpenCodeRemoteApp target (if not already linked)."
