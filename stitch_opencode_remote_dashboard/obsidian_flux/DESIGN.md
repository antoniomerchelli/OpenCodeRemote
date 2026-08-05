---
name: Obsidian Flux
colors:
  surface: '#131314'
  surface-dim: '#131314'
  surface-bright: '#39393a'
  surface-container-lowest: '#0e0e0f'
  surface-container-low: '#1c1b1c'
  surface-container: '#201f20'
  surface-container-high: '#2a2a2b'
  surface-container-highest: '#353436'
  on-surface: '#e5e2e3'
  on-surface-variant: '#c1c6d7'
  inverse-surface: '#e5e2e3'
  inverse-on-surface: '#313031'
  outline: '#8b90a0'
  outline-variant: '#414755'
  surface-tint: '#adc6ff'
  primary: '#adc6ff'
  on-primary: '#002e69'
  primary-container: '#4b8eff'
  on-primary-container: '#00285c'
  inverse-primary: '#005bc1'
  secondary: '#c0c1ff'
  on-secondary: '#1000a9'
  secondary-container: '#3131c0'
  on-secondary-container: '#b0b2ff'
  tertiary: '#ddb7ff'
  on-tertiary: '#490080'
  tertiary-container: '#b76dff'
  on-tertiary-container: '#400071'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#d8e2ff'
  primary-fixed-dim: '#adc6ff'
  on-primary-fixed: '#001a41'
  on-primary-fixed-variant: '#004493'
  secondary-fixed: '#e1e0ff'
  secondary-fixed-dim: '#c0c1ff'
  on-secondary-fixed: '#07006c'
  on-secondary-fixed-variant: '#2f2ebe'
  tertiary-fixed: '#f0dbff'
  tertiary-fixed-dim: '#ddb7ff'
  on-tertiary-fixed: '#2c0051'
  on-tertiary-fixed-variant: '#6900b3'
  background: '#131314'
  on-background: '#e5e2e3'
  surface-variant: '#353436'
typography:
  display-lg:
    fontFamily: Geist
    fontSize: 48px
    fontWeight: '600'
    lineHeight: 56px
    letterSpacing: -0.04em
  headline-lg:
    fontFamily: Geist
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-lg-mobile:
    fontFamily: Geist
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.02em
  body-md:
    fontFamily: Geist
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
    letterSpacing: -0.01em
  label-sm:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.02em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 8px
  container-padding: 32px
  gutter: 24px
  section-gap: 64px
---

## Brand & Style

The design system shifts from a utilitarian terminal to a premium, high-fidelity digital workspace. It targets sophisticated power users who value precision, calm, and performance. The aesthetic is a hybrid of **Minimalism** and **Glassmorphism**, characterized by deep ink-like surfaces, subtle atmospheric gradients, and surgical-grade alignment. 

The emotional response should be one of "effortless power"—a professional tool that feels like luxury hardware. We achieve this by replacing harsh terminal borders with soft light-leaks, high-blur backdrops, and generous whitespace that allows the content to breathe.

## Colors

The palette is anchored in a multi-layered dark mode. The base is not pure black, but a deep charcoal (`#0F0F10`) to allow for subtle depth through stacking. 

- **Primary:** A vibrant, high-end blue used for focus states and critical actions.
- **Accents:** Secondary and Tertiary colors are reserved for data visualization and subtle ambient glows.
- **Surface Tones:** Instead of borders, use "Surface Elevated" (`#1A1A1C`) and "Surface Overlay" (`#242427`) to differentiate depth.
- **Gradients:** Use linear gradients (45-degree angle) with low opacity (10-15%) for container backgrounds to simulate light hitting a high-end matte surface.

## Typography

This design system utilizes **Geist** for its systematic, neutral, yet premium feel. It provides the "modern developer tool" aesthetic while remaining highly legible. **JetBrains Mono** is used sparingly for labels, metadata, and technical readouts to nod to its cybernetic heritage without overwhelming the UI.

All headings should use tight letter-spacing to feel "locked-in" and architectural. Body text should remain clean with generous line-height for readability against the dark background.

## Layout & Spacing

The layout philosophy moves away from dense, left-aligned terminal grids to a **centered, balanced fluid grid**. Use a 12-column system for desktop with significant outer margins (up to 120px) to focus the user's attention on the center of the screen.

- **Whitespace:** Increase vertical spacing between sections to create a sense of premium "breathing room."
- **Alignment:** Every element must align to an 8px baseline grid. 
- **Mobile:** Transition to a single-column layout with 20px side margins, maintaining the large corner radii.

## Elevation & Depth

Depth is communicated through **Tonal Layers** and **Ambient Shadows**. 

1. **The Floor:** The deepest layer is the base neutral color.
2. **The Surface:** Floating containers use a slightly lighter hex and a 1px "inner glow" stroke (top-down) at 10% white opacity to simulate a chamfered edge.
3. **Shadows:** Use extremely soft, large-radius shadows (e.g., `box-shadow: 0 20px 40px rgba(0,0,0,0.4)`).
4. **Backdrop Blur:** For overlays and navigation bars, use a 20px Gaussian blur with a 60% transparent surface color to create a glassmorphic effect.

## Shapes

We are abandoning the sharp 4px corners of the previous system for a much softer, modern profile. 

- **Base Components:** 12px (rounded-md).
- **Cards & Modals:** 24px (rounded-xl).
- **Inputs:** 8px to maintain a slightly more structured feel than the outer containers.
- **Buttons:** Fully pill-shaped or 12px depending on the context of the internal icon.

## Components

- **Buttons:** Primary buttons should feature a subtle top-to-bottom gradient. No harsh borders; use a faint outer glow on hover to indicate interactivity.
- **Cards:** Replace heavy borders with a 1px solid stroke at 10% opacity. Use a centered layout for card content to enhance the high-end feel.
- **Inputs:** Use a subtle inset shadow to create a "pressed" look into the surface, with a primary-colored glow for the focus state.
- **Lists:** Increase the vertical padding between list items. Use soft dividers that don't reach the edges of the container.
- **Chips/Badges:** Use a "tonal" approach—semi-transparent background of the label color (e.g., 10% Blue background with 100% Blue text) and high roundedness.
- **Navigation:** A centered "floating" dock or top-bar with a heavy backdrop blur and 24px rounded corners.