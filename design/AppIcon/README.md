# Chat42 app icon — Liquid Glass source

The icon that ships is `Chat42/Resources/AppIcon.icon`, an Icon Composer bundle.
Everything in it is generated from the geometry in `generate.py`:

```sh
python3 design/AppIcon/generate.py
```

That one command rewrites the editable SVG components here, the `.icon` bundle, and
the flat PNG fallback in `Assets.xcassets/AppIcon.appiconset`. Never hand-edit the
generated files — change `generate.py` and re-run it.

```
design/AppIcon/
  generate.py               the source of truth for all icon geometry
  A-answer/icon.svg         the layer that ships (bubble + numerals composed)
  A-answer/01-bubble.svg    component, easier to edit in isolation
  A-answer/02-numerals.svg  component
  B-dialogue/*.svg          the alternate direction, not currently shipped
  pitch.html                the design presentation
```

## Palette

Sampled from the existing wordmark, so the icon and the app agree.

| Role | Hex |
|---|---|
| Crimson (bubble) | `#990000` |
| Cream (numerals) | `#F4F7F5` |
| Mist (background gradient) | `#A9CFD9`, auto-gradient |
| Ink (direction B only) | `#002D3C` |

## Why the shipping artwork is one layer, not two

The design was drawn as two groups — bubble behind, numerals in front — because that
is what Apple's layering guidance suggests, and it is what an earlier version of this
file described. Compiling it with `actool` and looking at the render showed that was
wrong:

- **Two groups.** The numerals almost vanished. A second Liquid Glass group stacked
  on a dark one picks up what is beneath it and loses nearly all contrast.
- **Two groups, specular and translucency off on the numerals.** No better. Both
  settings measurably changed the output, so they were applied — they just don't
  recover contrast.
- **Two layers inside one group.** Worse: the group renders as a single glass object
  and the numerals disappeared completely.
- **Numerals knocked out of the bubble with an SVG mask.** Works, and `actool`
  honours the mask — but the numerals then take the background colour, which inverts
  in dark mode.
- **One layer, numerals painted into the bubble.** Renders exactly as designed. This
  is what ships.

The tradeoff is that bubble and numerals can no longer be recoloured independently
per appearance; the system derives dark and mono from the single layer. That is worth
it for an icon that is legible.

The component SVGs are kept because they are easier to edit than the composed file —
`generate.py` emits all three from the same geometry.

## The `.icon` bundle

```
Chat42/Resources/AppIcon.icon/
  icon.json
  Assets/icon.svg
```

`icon.json` is deliberately minimal — it sets the background gradient and one group,
and lets every Liquid Glass property default. Its schema was taken from a document
saved by Icon Composer rather than guessed, and verified by compiling with `actool`
and inspecting the rendered result.

Two constraints the artwork has to respect, both enforced by Icon Composer:

- **No text elements.** The `42` is stroked geometry, not type. Icon Composer rejects
  SVGs containing text, and a font would need licensing besides.
- **No canvas mask, background or baked effects.** The system applies the squircle,
  the material, and the specular pass. The flat PNG fallback is the one place the
  mask and gradient *are* baked in, because nothing else will apply them there.

To open it: `open Chat42/Resources/AppIcon.icon`.

## How it reaches the app

`build.sh` takes one of two paths:

| | Condition | Result |
|---|---|---|
| Preferred | `xcrun -f actool` succeeds | `actool` compiles `AppIcon.icon` into `Assets.car` (layered, dynamic, with dark and tinted variants) plus a derived `AppIcon.icns`. Sets `CFBundleIconName`. |
| Fallback | no `actool` | `iconutil` builds `AppIcon.icns` from the committed flat PNGs. Working icon, no dynamic material. |

This keeps the property that made `build.sh` worth having: it still builds with only
the Command Line Tools. Xcode is an upgrade, not a requirement.

`project.yml` lists `AppIcon.icon` in the target's resources. Xcode uses it in place
of the `AppIcon` in `Assets.xcassets`; the appiconset stays for the fallback path.
Compiling both together produces no warnings and the `.icon` wins — verified.
