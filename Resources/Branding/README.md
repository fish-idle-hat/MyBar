# TheBar icon

Created with the built-in imagegen tool from the user's supplied avatar reference.
The app icon is a completely redrawn illustration, not a crop of the reference.
The generated master is `../TheBarIcon.png`. Mechanical size exports for the
macOS asset catalog are reproducible with `zsh scripts/update-app-icon.sh`.

## Generation prompt

Use case: logo-brand. Asset type: production macOS app icon for TheBar, a personal menu-bar system utility. Input image 1 is a CHARACTER AND PALETTE REFERENCE ONLY, not an image to crop or paste. Completely redraw and redesign this avatar as a polished, distinctive small-scale macOS icon. Preserve the recognizable identity: oversized playful orange koi-fish hat with one large glossy eye and side fins, swept silver-white hair, relaxed half-lidded plum eyes, a few simplified dark-red face markings, black collar, and one mint-green bubblegum sphere. Style: premium clean illustrated 3D enamel/toy mascot with carefully controlled soft gloss, bold simplified shapes, lovely layered depth and crisp contours, not an anime screenshot and not a photo. Tight centered head-and-collar portrait within a subtly beveled warm ivory rounded-square macOS tile. Hat and bubble should be dominant memorable shapes; face still visible and recognizable. Restrained orange, silver, mint and charcoal palette inspired entirely by the avatar. Readable at 32px. Build icon artwork large inside tile with balanced 8 percent inset around it. A single finished square icon shown straight on, not an icon grid, not a mockup. Canvas square 1024x1024. Actual transparent outside rounded tile, with only a very soft small shadow. No text, no letters, no app name, no charts, no extra symbols, no watermark. This should feel like an entirely new professionally art-directed app icon based on the supplied avatar, not the original avatar simply placed on a background.

## Edge refinement prompt

Use case: precise-object-edit. This image is the edit target, a finished TheBar macOS app icon. Keep the illustrated orange fish hat, silver-haired face, red facial marks, mint bubble and warm ivory beveled rounded-square tile EXACTLY in this established design and palette. Only clean and refine the outer silhouette for production app-icon export: remove ALL stray floating white flecks, colored dots, grain, fringe, detached pixels and background artifacts outside the rounded tile; ensure outer transparent regions are truly alpha zero. Reduce the composition just slightly so the entire fish fin at the top and all of the tile are safely contained with 6 percent transparent margin on every side and absolutely no clipping. Inside the tile and character must be opaque. Very clean anti-aliased edges, refined restrained shadow. Square 1024x1024 canvas. No text or new objects, no redesign of the character, no mockup. One single finished app-icon image.

## Compatibility

The visible name and packaged artifact are TheBar / TheBar.app. The original
`local.thermobar.app` bundle identifier, `ThermoBar` executable, UserDefaults
keys, helper identifiers and Application Support paths are deliberately retained.
Existing history and preferences therefore require no migration. macOS may ask
to reconfirm permissions after a locally ad-hoc-signed build changes.
