"""The two skater bodies the character builder offers, as data for the skater stages.

Every stage (body, face, skin, hair, clothes, animation re-solve) takes one of these
profiles. MALE holds exactly the values the original skater was built with (the stages'
own defaults), so building him through a profile gives the same asset as before; FEMALE
is the second MPFB2 character. Both come from the same MakeHuman base mesh, so they share
its topology and UV layout vertex for vertex - the garments use that to fit both bodies
from one set of cut masks and to share their baked textures.
"""
import skater_body as SB
import skater_skin as SS

MALE = dict(
    key="male",
    suffix="",                       # texture/image name suffix (keeps work/tex files apart)
    blend="skater",                  # blender/work/<blend>.blend (renders load it)
    glb="skater.glb",
    macro=SB.MACRO,
    targets=SB.TARGETS,
    face_src="face_albedo",
    face_pairs=SS.FACE_PAIRS,
    eye_openings=SS.EYE_OPENINGS,
    hair_style="crop",
)

# ------------------------------------------------------------------ female
# An athletic woman of about 1.65 m (MakeHuman age 0.45, early twenties), mixed heritage,
# with an original face: oval head, high cheekbones, full lips, a straight nose with a
# soft tip, almond eyes with lifted outer corners, a longer lower face (matched to the
# face photo's proportions so its projection is not squashed).
FEMALE_MACRO = {"gender": 0.0, "age": 0.45, "muscle": 0.6, "weight": 0.42, "height": 0.58,
                "proportions": 0.85, "cupsize": 0.45, "firmness": 0.6,
                "race": {"asian": 0.2, "caucasian": 0.55, "african": 0.25}}
FEMALE_TARGETS = [
    ("head-oval", 0.5), ("head-fat-decr", 0.3), ("head-age-decr", 0.2),
    ("chin-prominent-incr", 0.15), ("chin-width-decr", 0.2), ("chin-height-incr", 0.4),
    ("nose-point-width-decr", 0.15), ("nose-nostrils-width-incr", 0.1), ("nose-hump-decr", 0.1), ("nose-point-up", 0.1),
    ("nose-scale-vert-incr", 0.5), ("nose-trans-down", 0.2), ("mouth-trans-down", 1.0),
    ("mouth-lowerlip-volume-incr", 0.25), ("mouth-upperlip-volume-incr", 0.2), ("mouth-cupidsbow-incr", 0.3),
    ("l-cheek-bones-incr", 0.35), ("r-cheek-bones-incr", 0.35), ("l-cheek-volume-decr", 0.3), ("r-cheek-volume-decr", 0.3),
    ("l-eye-scale-incr", 0.15), ("r-eye-scale-incr", 0.15), ("l-eye-height2-incr", 0.2), ("r-eye-height2-incr", 0.2),
    ("l-eye-corner2-up", 0.15), ("r-eye-corner2-up", 0.15), ("l-eye-trans-up", 0.3), ("r-eye-trans-up", 0.3),
    ("eyebrows-angle-up", 0.1), ("forehead-scale-vert-incr", 0.1), ("neck-scale-horiz-decr", 0.1),
    ("hip-scale-horiz-incr", 0.08), ("measure-waist-circ-decr", 0.2),
    ("l-upperleg-muscle-incr", 0.25), ("r-upperleg-muscle-incr", 0.25),
    ("l-lowerleg-muscle-incr", 0.3), ("r-lowerleg-muscle-incr", 0.3),
    ("l-lowerarm-muscle-incr", 0.15), ("r-lowerarm-muscle-incr", 0.15),
]
# Face photo (textures_src/face_albedo_f.png, an original generated woman): landmark pairs
# measured on a front orthographic render of this head (same frame as the male's, see
# skater_skin.FACE_FRAME) and on the photo.
FEMALE_FACE_PAIRS = [   # (mesh front-view px), (photo px)
    ((378, 392), (351, 461)), ((646, 392), (663, 461)),          # pupils
    ((431, 400), (425, 478)), ((590, 400), (592, 479)),          # inner eye corners
    ((325, 391), (272, 456)), ((700, 391), (748, 458)),          # outer eye corners
    ((377, 369), (351, 437)), ((646, 369), (663, 437)),          # upper lid, middle
    ((377, 413), (351, 490)), ((646, 413), (663, 490)),          # lower lid, middle
    ((512, 540), (507, 628)),                                    # nose tip
    ((448, 570), (425, 665)), ((580, 570), (590, 665)),          # alae
    ((512, 592), (507, 690)),                                    # subnasale
    ((419, 707), (378, 812)), ((605, 707), (640, 812)),          # mouth corners
    ((512, 682), (507, 760)), ((512, 704), (507, 812)), ((512, 757), (507, 875)),  # lips
    ((512, 868), (507, 1012)),                                   # chin
    ((218, 520), (172, 605)), ((800, 520), (845, 605)),          # face contour: cheeks
    ((275, 720), (211, 828)), ((746, 720), (816, 828)),          # jaw
    ((342, 820), (250, 952)), ((683, 820), (776, 952)),
    ((512, 230), (507, 275)), ((345, 260), (313, 308)), ((680, 260), (702, 308)),  # forehead
]
FEMALE_EYE_OPENINGS = [((351, 461), 88, 32), ((663, 461), 88, 32)]

FEMALE = dict(
    key="female",
    suffix="_f",
    blend="skater_female",
    glb="skater_female.glb",
    macro=FEMALE_MACRO,
    targets=FEMALE_TARGETS,
    face_src="face_albedo_f",
    face_pairs=FEMALE_FACE_PAIRS,
    eye_openings=FEMALE_EYE_OPENINGS,
    # photo clean-up: where the (pulled back, near-black) hair is, no stubble to soften,
    # brows eased a touch less than his (they are hers, the cards add depth)
    photo_hair_top=200, photo_hair_sides=(190, 835), photo_stubble=False,
    photo_lips=(507, 815, 140, 70), photo_brows=(330, 405, 200, 820), photo_brow_ease=0.0,
    stubble=False,
    scalp_smooth=14, scalp_gain=1.2,    # the painted scalp under the pulled-back hair fades out softly
    skin_base=(0.50, 0.30, 0.20),    # linear; the face photo colour-matches it anyway
    hair_color=(0.018, 0.012, 0.009),
    iris_tint=(1.18, 0.80, 0.52), iris_gain=0.55,
    brow=dict(count=280, color=(0.02, 0.014, 0.011), rise=0.018, arch=0.006, drop=0.005,
              thick=0.0085, taper=0.6, length=(0.005, 0.009), width=(0.0014, 0.0022)),
    lashes=dict(upper=dict(strands=150, curl=0.6, thickness=0.85, seed=13),
                lower=dict(strands=50, curl=0.3, thickness=0.6, seed=14), length=1.35),
    hair_style="bun",
)

PROFILES = {"male": MALE, "female": FEMALE}
