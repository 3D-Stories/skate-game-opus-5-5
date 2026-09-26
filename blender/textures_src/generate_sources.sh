#!/bin/bash
# Generates the photographic texture sources with the shared benchmark image tool.
# Run from the project root. Each call is logged to imagegen-log.jsonl.
# These PNGs are committed; build_all.py only reads them (it never calls the tool).
set -u
T=~/agents/virgil/opus55-3way_09.22.26/tools/imagegen.py
O=blender/textures_src
gen() { [ -f "$O/$1.png" ] || python3 "$T" "$2" -o "$O/$1.png" --size 1024x1024; }
FLAT="perfectly flat even diffuse lighting, no shadows, no highlights, orthographic top-down view filling the whole frame, seamless tileable texture, photographic, ultra detailed"
gen skin_pores "Macro photograph of human skin surface of a young man's cheek, visible pores, fine lines and subtle vellus hair follicles, natural light-medium skin tone with slight redness variation, $FLAT" &
gen hoodie_fleece "Close-up photograph of heavyweight cotton fleece hoodie fabric, knit jersey loops visible, heather charcoal grey, slight pilling, $FLAT" &
gen denim "Close-up photograph of worn indigo blue denim jeans fabric, diagonal twill weave, faded fibers and slight whiskering, $FLAT" &
gen suede "Close-up photograph of scuffed grey suede leather from a skate shoe, brushed nap direction variation, light abrasion marks, $FLAT" &
wait
gen griptape "Close-up photograph of black skateboard griptape, coarse silicon carbide grit, faint grey scuff marks and dust, $FLAT" &
gen concrete_floor "Photograph of worn polished warehouse concrete floor, grey, oil stains, hairline cracks, tire scuffs and patched areas, $FLAT" &
gen plywood "Photograph of a scuffed birch plywood skateboard ramp surface, wood grain, black wheel marks, grey urethane scuffs and countersunk screws in a grid, $FLAT" &
gen brick "Front photograph of an old red brick warehouse wall, grimy mortar, soot stains and efflorescence, running bond, $FLAT" &
wait
gen painted_steel "Close-up photograph of old industrial steel painted dark blue-grey, chipped paint, scratches and orange rust spots, $FLAT" &
gen crate_wood "Photograph of weathered pine wooden crate planks, horizontal boards, nail holes, stamped shipping marks faded, $FLAT" &
gen diamond_plate "Photograph of worn galvanized steel diamond plate floor panel, scratches and dirt in grooves, $FLAT" &
gen corrugated "Front photograph of weathered galvanized corrugated metal wall panel, vertical corrugations, water stains and rust streaks, $FLAT" &
wait
gen iris "Extreme macro photograph of a single human eye iris, hazel green-brown with detailed radial fibers and crypts, perfectly centered and straight-on, round black pupil in the exact center, the iris fills the frame as a circle on black background, flat lighting, no reflections, no eyelids" &
gen cinderblock "Front photograph of a painted cinder block wall, off-white paint with grime, scuffs and black skate marks near the bottom, $FLAT" &
gen deck_graphic "Original skateboard deck bottom graphic artwork, vertical portrait composition centered, bold screen-printed illustration of a stylized roaring tiger head with lightning bolts, red cream and black palette, halftone shading, clean edges, flat print scan, no text, no logos" --size 1024x1024 &
gen cotton_tee "Close-up photograph of white cotton t-shirt jersey knit fabric, fine knit texture, $FLAT" &
wait
gen face_albedo "Cross-polarized photogrammetry albedo capture of an original young man in his early twenties, not resembling any real person, perfectly straight-on frontal view, head level and centered, face filling most of the frame from hairline to chin, neutral relaxed expression, mouth closed, eyes open looking into the lens, short brown hair pushed back so the forehead and hairline are visible, both ears visible, light-medium warm skin tone with natural pores, faint freckles and slight redness on nose and cheeks, faint stubble, completely flat even diffuse lighting with no shadows and no specular highlights, plain mid grey background, ultra detailed skin texture"
echo ALLDONE
