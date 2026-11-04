# Hand adjudications (Claude, 2026-11-05) → names/adjudication.json.
# Each entry points at a taxon id the snapshot/API returned; evidence says why.
import json, sys
A = {}
def add(label, rel, tid, ev, kind="adjudicated", flow=None):
    d = {"relation": rel, "inat_taxon_id": tid, "evidence": ev, "kind": kind}
    if flow: d["photo_flow"] = flow
    A[label] = d
S, O, L, N = "synonym", "orthographic", "lump", "none"
add("Acacia littorea", S, 1474992, "iNat swapped inactive 'Acacia littorea' (564313) into A. trapezoidea; GBIF backbone: A. littorea = synonym of A. trapezoidea; 404 RG obs, all Australian; APC's listed synonym 'A. praemorsa' is a homonym of the separately accepted APC species", "inat-swap+gbif")
add("Anthosachne fertilis", L, 485775, "iNat lists A. fertilis under A. kingiana subsp. multiflora, which APC accepts as its own infraspecies: iNat lumps, photos cannot be attributed", "inat-q", "none")
add("Blechnum deltoides", S, 1348449, "iNat swapped 'Blechnum deltoides' into Cranfillia deltoides (GBIF agrees); that taxon already feeds the shipped extra label 'Cranfillia deltoides' (not an APC name) — same species twice in U: merge", "inat-swap/duplicate", "merge")
add("Bromheadia pulchra", S, 142176, "iNat lists 'Bromheadia pulchra' under B. finlaysoniana and GBIF agrees; APC does not accept B. finlaysoniana, so iNat's concept = APC's plus extralimital (SE Asian) populations; 8 of 129 RG obs Australian", "inat-q+gbif")
add("Cadetia wariana", S, 1120659, "iNat lists 'Cadetia wariana' under Dendrobium funiforme and GBIF agrees; D. funiforme not an APC name; 1 RG obs (not Australian)", "inat-q+gbif")
add("Callistemon glaucus", S, 589711, "iNat lists 'Callistemon glaucus' under Melaleuca glauca (Craven's transfer); GBIF lists M. glauca among its synonyms; 192 RG obs all Australian; APC's other uses of 'Melaleuca glauca' (under M. eurystoma / M. nervosa) are other authors' homonyms; no label holds the taxon", "inat-q+gbif")
add("Codariocalyx microphyllus", S, 1275055, "iNat swapped the APC synonym 'Desmodium microphyllum' into Leptodesmia microphylla; GBIF accepted name = Leptodesmia microphylla; 7 RG obs, none Australian", "inat-swap+gbif")
add("Corunastylis cuspidata", S, 1233295, "GBIF accepted name Genoplesium cuspidatum; same epithet, Corunastylis→Genoplesium is iNat's pattern (56 labels); 14 RG obs all Australian; no label holds it", "gbif+genus-transfer")
add("Corunastylis tepperi", S, 1229075, "iNat keeps Genoplesium tepperi as an active species (107 RG obs, all Australian) — the APC concept; iNat's name search also files 'Corunastylis tepperi' under G. nigricans (a broad old synonym entry, as GBIF) but that would make it a lump while iNat still maintains G. tepperi itself; Corunastylis→Genoplesium pattern 56×", "genus-transfer")
add("Cyanicula gertrudae", O, 1145690, "APC itself lists 'Cyanicula gertrudiae' as orthographic variant; iNat uses that spelling; 13 RG obs all Australian; the other APC use (under C. gemmata) is a pro-parte synonym, no label holds the taxon", "apc-syn/ortho")
add("Cyperus pygmaeus", S, 1260471, "APC nomenclatural synonym (same type) 'Cyperus michelianus subsp. pygmaeus' = iNat's taxon; widespread Old World species (2 of 27 RG obs Australian); only obs identified to the subspecies flow", "apc-syn/infraspecies")
add("Dendrobium stuartii", S, 931963, "GBIF backbone (WCVP) sinks D. stuartii into D. macrostachyum; not an APC name; 4 of 48 RG obs Australian (iNat users file Australian plants under it)", "gbif")
add("Deyeuxia decipiens", S, 1532648, "GBIF accepted name Calamagrostis decipiens; iNat follows Deyeuxia→Calamagrostis (pattern 4×); 5 of 7 RG obs Australian", "gbif+genus-transfer")
add("Deyeuxia mckiei", S, 1518805, "GBIF accepted name Calamagrostis mckiei; Deyeuxia→Calamagrostis pattern 4×; 1 RG obs, Australian", "gbif+genus-transfer")
add("Dienia montana", S, 427505, "GBIF accepted name Dienia ophrydis; not an APC name; 51 of 314 RG obs Australian", "gbif")
add("Dockrillia calamiformis", L, 534394, "iNat swapped 'Dockrillia calamiformis' into Dendrobium teretifolium, which already feeds APC Dockrillia teretifolia: iNat lumps two APC species", "inat-swap", "none")
add("Dunbaria singuliflora", S, 974363, "GBIF accepted name Dunbaria debilis; not an APC name; 3 RG obs all Australian", "gbif")
add("Eschenbachia aegyptiaca", S, 937391, "iNat swapped two APC synonyms (Conyza aegyptiaca, Erigeron aegyptiacus) into Nidorella aegyptiaca; GBIF accepted name the same; 10 RG obs, none Australian", "inat-swap+gbif")
add("Eucalyptus copulans", L, 1077024, "iNat swapped 'Eucalyptus copulans' into E. moorei subsp. moorei, which APC accepts separately: iNat lumps", "inat-swap", "none")
add("Galbulimima baccata", S, 803380, "GBIF accepted name G. belgraveana; not an APC name; 11 of 13 RG obs Australian", "gbif")
add("Glochidion perakense", L, 340543, "GBIF sinks it into G. zeylanicum, but iNat's G. zeylanicum also absorbs APC G. sumatranum (iNat swap) and its 464 Australian obs are mostly that: two APC species ↔ one iNat taxon", "gbif", "none")
add("Hybanthus volubilis", S, 1436632, "GBIF accepted name Pigea volubilis; Hybanthus→Pigea is iNat's pattern (6×); 2 RG obs, Australian", "gbif+genus-transfer")
add("Lechenaultia hortii", O, 1598902, "genus spelling: iNat uses 'Leschenaultia' (28 labels follow the pattern); same epithet, 6 RG obs all Australian", "genus-orthography")
add("Lechenaultia lutescens", O, 1598903, "genus spelling: iNat uses 'Leschenaultia' (28 labels); same epithet, 1 RG obs, Australian", "genus-orthography")
add("Leucopogon lasiostachyus", O, 1033958, "GBIF accepted spelling 'Leucopogon lasiostachys'; 3 RG obs all Australian", "gbif/ortho")
add("Luisia atacta", L, 552333, "GBIF sinks both APC L. atacta and APC L. corrugata into L. tristis: two APC species ↔ one iNat taxon", "gbif", "none")
add("Luisia corrugata", L, 552333, "GBIF sinks both APC L. atacta and APC L. corrugata into L. tristis: two APC species ↔ one iNat taxon", "gbif", "none")
add("Nelsonia campestris", S, 347373, "GBIF accepted name Nelsonia canescens; not an APC name; 55 of 384 RG obs Australian", "gbif")
add("Nervilia dallachyana", S, 369228, "GBIF accepted name Nervilia plicata; not an APC name; 9 of 157 RG obs Australian", "gbif")
add("Paspalidium gracile", S, 1377602, "iNat swapped 'Paspalidium gracile' itself into Setaria brownii; APC lists Setaria brownii as its nomenclatural synonym (the other APC use under S. surgens is a homonym); 20 RG obs all Australian", "inat-swap+apc-syn")
add("Sauropus paucifolius", S, 1519342, "Sauropus→Synostemon is iNat's pattern (4×); same epithet, 18 RG obs all Australian, no label holds it", "genus-transfer")
add("Sehima nervosum", O, 633610, "gender ending (Sehima neuter vs iNat 'nervosa'); 16 of 42 RG obs Australian, widespread tropical grass", "ortho")
add("Trema orientalis", O, 147425, "gender ending ('orientale' on iNat) of the Linnaean name; widespread species, 19 of 3,594 RG obs Australian", "ortho")
add("Cheilocostus potierae", L, 764909, "iNat lists it under Hellenia speciosa (GBIF agrees), which APC accepts as a separate species: two APC species ↔ one iNat taxon", "inat-q+gbif", "none")
add("Cyperus bifax", L, 76593, "iNat lists it under Cyperus rotundus, a separately accepted APC species: lump", "inat-q", "none")
add("Ipomoea brownii", L, 164092, "iNat lists it under Ipomoea obscura (GBIF agrees), a separately accepted APC species: lump", "inat-q+gbif", "none")
add("Eria kingii", S, 1425310, "iNat files 'Eria kingii' under two taxa (pro parte): Pinalia moluccana holds all 14 Australian RG obs (no label holds it), Mycaranthes oblitterata has 1 non-Australian obs — the Australian part is P. moluccana", "inat-q")
add("Najas foveolata", S, 283781, "iNat lists 'Najas foveolata' under N. indica and GBIF agrees; not an APC name; 4 RG obs, none Australian (photos extralimital)", "inat-q+gbif")
add("Nervilia crociformis", S, 963748, "iNat lists 'Nervilia crociformis' under N. simplex and GBIF agrees; not an APC name; 105 RG obs, none Australian (photos extralimital)", "inat-q+gbif")
add("Polyscias bellendenkerensis", O, 866513, "spelling variant 'bellendenkeriensis' (GBIF lists it as a synonym); 4 RG obs all Australian, no label holds it", "gbif/ortho")
add("Solanum callium", S, 544073, "iNat lists 'Solanum callium' under S. spirale and GBIF agrees; not an APC name; 4 of 14 RG obs Australian", "inat-q+gbif")
add("Tasmannia vickeryana", O, 893123, "spelling variant 'vickeriana' (GBIF fuzzy match + synonym); 24 RG obs all Australian, no label holds it", "gbif/ortho")
for k in ("Eulalia trispicata", "Festuca archeri", "Malaccotristicha australis", "Najas foveolata",
          "Nervilia crociformis", "Pterostylis neopolyphylla"):
    pass  # left 'none' (see notes): GBIF-only with no Australian obs, or extralimital homonyms
json.dump(A, open(sys.argv[1], "w"), indent=1, ensure_ascii=False)
print(len(A))
