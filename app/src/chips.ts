// Hand-curated short legend-chip labels (plain truncation produced
// near-identical twins). Kept in a dependency-free module so tests can
// import it node-side and assert the keys stay in sync with the generated
// unit tables — a renamed group otherwise falls back to truncation
// silently.

/** Geology legend groups (strat_name top levels) -> chip labels. */
export const GEO_CHIPS: Record<string, string> = {
  "Proterozoic basement and parautochthonous rocks": "Proterozoic",
  "Middle-Late Cambrian Volcanic and volcano-sedimentary sequences": "Cambrian volcanics",
  "Devonian - Carboniferous granitoids and related rocks": "Granites",
  "Late Carboniferous to Triassic sedimentary sequences": "Permian–Triassic",
  "Undifferentiated Cenozoic sequences": "Recent",
  "Late Cambrian - Lower Devonian sedimentary sequences": "Camb–Dev. seds",
  "Early Ordovician to Early Devonian turbidite sequence": "Turbidites",
  "Early Cambrian Allochthonous sequences": "Early Cambrian",
  "Jurassic igneous rocks": "Dolerite",
  "Cretaceous igneous rocks": "Cretaceous igneous",
  "Devonian cavern fillings": "Cavern fillings",
  "Other units": "Other",
};

/** NVIS Major Vegetation Groups present in the Tasmanian pre-1750 layer ->
 * chip labels (five group names start with "Eucalypt"). Tests assert exact
 * key equality with pre1750_units.json's groups. */
export const PRE_CHIPS: Record<string, string> = {
  "Rainforests and Vine Thickets": "Rainforest",
  "Eucalypt Tall Open Forests": "Tall forests",
  "Eucalypt Open Forests": "Euc. forests",
  "Eucalypt Woodlands": "Euc. woodlands",
  "Eucalypt Open Woodlands": "Open woodlands",
  "Other Open Woodlands": "Other woodlands",
  "Acacia Forests and Woodlands": "Acacia",
  "Callitris Forests and Woodlands": "Callitris",
  "Casuarina Forests and Woodlands": "Casuarina",
  "Melaleuca Forests and Woodlands": "Melaleuca",
  "Other Forests and Woodlands": "Other forests",
  "Mallee Woodlands and Shrublands": "Mallee",
  "Low Closed Forests and Tall Closed Shrublands": "Closed scrub",
  "Acacia Shrublands": "Acacia shrubs",
  "Other Shrublands": "Shrublands",
  "Heathlands": "Heath",
  "Tussock Grasslands": "Tussock grass",
  "Other Grasslands, Herblands, Sedgelands and Rushlands": "Sedges & herbs",
  "Chenopod Shrublands, Samphire Shrublands and Forblands": "Saltmarsh",
  "Unclassified native vegetation": "Unclassified",
  "Naturally bare - sand, rock, claypan, mudflat": "Bare",
};
