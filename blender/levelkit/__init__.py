"""The level kit: reusable Blender generators for skate parks and the build of data-defined
levels. See docs/LEVELS.md for the step-by-step guide.

    geo.py         ramps (quarter/half pipes, spines, banks, kickers, funboxes), bowls, stairs,
                   rails, ledges, benches, pipes, walls with openings, window frames, roofs
    materials.py   PBR texture sets from the photo sources + emissive / glass materials
    lighting.py    lights and the two-pass Cycles lightmap bake
    breakables.py  grilles, boarded walls, knock-over signs (separate nodes + game data)
    props.py       lamps, lifeguard chair, pool ladder, clock, boilers
    level.py       reads levels/<id>/level.json and builds the GLB, data JSON and lightmap
    scaffold.py    creates a new level skeleton (plain python3, no Blender)
"""
