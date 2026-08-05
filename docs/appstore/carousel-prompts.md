# App Store carousel — image generation prompts

## Read this first — it decides whether you get rejected

**Never let an AI generate the phone screen itself.** App Store Review
guideline 2.3.3 requires screenshots to show the app actually in use. A
generated "app UI" is a rejection, and a fast one — reviewers see thousands of
these.

What you *can* generate is everything **behind and around** the real
screenshot: the background, the lighting, the texture, the scene. Then you
composite the real capture on top.

So the workflow is:

1. Generate a **1320 × 2868 background** with an empty area where the phone goes.
2. Drop the real screenshot from `docs/appstore/screenshots/` on top.
3. Add the headline text yourself (Figma, Canva, Keynote — anything).

Generators are bad at text. Ask for backgrounds with *space* for text, then set
the type yourself in a real font. Generated type is almost always subtly
misspelled or malformed.

---

## The house style to ask for

Paste this at the top of every prompt so the six slides look like one set:

> Style: clean, premium, Apple-like. Soft gradient background, generous
> negative space, no clutter, no text, no words, no letters, no UI elements, no
> phone mockups, no hands. Subtle depth — gentle light falloff, very soft
> shadow. Colour palette built around iOS system blue (#007AFF). Flat and
> modern, not glossy or 3D-rendered. Portrait 1320 × 2868 pixels.

Two rules that matter more than the wording:

- **Say "no text" explicitly, every time.** Models add gibberish type by default.
- **Keep the top third or bottom third empty.** That's where your headline goes,
  and where the real screenshot needs room to breathe.

---

## Slide-by-slide prompts

Each one pairs with a real screenshot already in `docs/appstore/screenshots/`.

### Slide 1 — pairs with `01-fair-spots-in-chat.png`
Headline you'll add: **It lives in your chat**

> [house style] A soft vertical gradient from light sky blue at the top to warm
> off-white at the bottom. Faint, very low-contrast abstract line work
> suggesting two paths converging toward a single point in the middle of the
> frame. Empty and calm. No text, no phone, no icons.

### Slide 2 — pairs with `02-everyones-drive-time.png`
Headline: **Fair means fair**

> [house style] A calm off-white background with a barely-visible pair of
> concentric ripple rings expanding from two separate points and overlapping in
> the centre, like two stones dropped in still water. Extremely subtle, low
> contrast, mostly empty space. No text, no phone, no icons.

### Slide 3 — pairs with `03-agreed-open-in-maps.png`
Headline: **Agree in one tap**

> [house style] A gentle gradient from pale mint green at the top to white at
> the bottom, suggesting resolution and confirmation. A single very soft
> circular glow centred in the upper third. Nothing else. No text, no phone, no
> icons, no checkmarks.

### Slide 4 — pairs with `04-search-like-maps.png`
Headline: **Search like Maps**

> [house style] A very light, abstract, top-down suggestion of a city street
> grid rendered in pale grey lines on white, fading out toward the edges of the
> frame. Almost a watermark — 10% opacity feel. Lots of clean white space. No
> text, no labels, no place names, no phone, no pins.

### Slide 5 — if you add a Pro slide
Headline: **Plan it ahead — Tween Pro**

> [house style] A deep indigo-to-blue gradient, richer and more premium than the
> other slides, with a soft scattering of faint light particles in the upper
> area, like a night sky at very low contrast. Empty centre. No text, no phone,
> no stars, no icons.

### Slide 6 — the closer
Headline: **No account. No server.**

> [house style] Pure, calm, near-white background with the faintest possible
> warm grey vignette at the edges. Absolutely minimal — the emptiest slide in
> the set. No text, no phone, no icons, no shapes.

---

## Composing the final slide

Layout that works, top to bottom:

| Zone | Height | Content |
|---|---|---|
| Top margin | ~180 px | empty |
| Headline | ~260 px | 1 line, ~110 pt bold, near-black |
| Subhead | ~120 px | 1 line, ~52 pt regular, 60% grey |
| Screenshot | ~2000 px | the real capture, corners rounded ~90 px |
| Bottom margin | rest | empty |

Headline and subhead pairs, matching the store description:

1. It lives in your chat — *Your friend doesn't need the app*
2. Fair means fair — *Everyone's drive time, side by side*
3. Agree in one tap — *Or counter with somewhere better*
4. Search like Maps — *Coffee, food, gas, or by name*
5. Plan it ahead — *Time, transit, reminders — Tween Pro*
6. No account. No server. — *Your location never leaves your phone*

Use the system font (SF Pro) so the type matches the app. Keep every headline
to one line — two-line headlines read as cluttered at thumbnail size, and the
first two slides are what most people ever see.

---

## If you'd rather skip all of this

The four raw screenshots in `docs/appstore/screenshots/` are already valid App
Store screenshots at exactly 1320 × 2868. Plenty of shipped apps use plain
captures with no marketing frame. Framed slides convert better, but an unframed
real screenshot is never a rejection — and a generated fake UI always is.
