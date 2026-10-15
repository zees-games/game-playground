#!/usr/bin/env python3
"""Vendors the models listed in tools/props_pack.tsv from a local Kenney asset folder into
assets/props/<kit>/ and writes each kit's props.json (without extents: run
tools/bake_props_pack.gd afterwards to measure them). Usage: build_props_pack.py <kenney 3D assets dir>"""
import csv, json, os, shutil, sys

src_root = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
out_root = os.path.join(here, "..", "assets", "props")
KITS = {
    "furniture": ("Furniture Kit/Models/GLTF format", 2.0, "Furniture Kit", "https://kenney.nl/assets/furniture-kit", ["Kenney"]),
    "food": ("Food Kit/Models/GLB format", 0.75, "Food Kit", "https://kenney.nl/assets/food-kit", ["Kenney"]),
    "survival": ("Survival Kit/Models/GLB format", 3.0, "Survival Kit", "https://kenney.nl/assets/survival-kit", ["Kenney"]),
    "nature": ("Nature Kit/Models/GLTF format", 2.5, "Nature Kit", "https://kenney.nl/assets/nature-kit", ["Kenney"]),
    "market": ("Mini Market/Models/GLB format", 1.6, "Mini Market", "https://kenney.nl/assets/mini-market", ["Kenney", "Fleur Keijsers", "Guus Vermeulen"]),
}
manifests = {k: {} for k in KITS}
for row in csv.reader(open(os.path.join(here, "props_pack.tsv")), delimiter="\t"):
    if not row or row[0].startswith("#"):
        continue
    kit, stem, pid, name, cat, mass, shape = row
    src_dir = os.path.join(src_root, KITS[kit][0])
    dest = os.path.join(out_root, kit)
    os.makedirs(dest, exist_ok=True)
    shutil.copy(os.path.join(src_dir, stem + ".glb"), os.path.join(dest, stem + ".glb"))
    tex = os.path.join(src_dir, "Textures")
    if os.path.isdir(tex) and not os.path.isdir(os.path.join(dest, "Textures")):
        os.makedirs(os.path.join(dest, "Textures"))
        shutil.copy(os.path.join(tex, "colormap.png"), os.path.join(dest, "Textures", "colormap.png"))
    manifests[kit][stem] = {"id": pid, "name": name, "category": cat, "mass": float(mass), "shape": shape}
for kit, (_, scale, title, url, authors) in KITS.items():
    doc = {
        "credit": {"author": " and ".join(authors) if len(authors) < 3 else ", ".join(authors[:-1]) + " and " + authors[-1],
                   "licence": "CC0 1.0", "url": url, "source": "Kenney " + title},
        "defaults": {"scale": scale},
        "props": manifests[kit],
    }
    json.dump(doc, open(os.path.join(out_root, kit, "props.json"), "w"), indent=1)
print({k: len(v) for k, v in manifests.items()})
