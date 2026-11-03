import Foundation
import Testing
@testable import IzzyKit

/// Bit-for-bit parity with the web implementation this engine was ported
/// from (app/src/search.ts at 04ea5d9). Each line is a query, a map centre
/// (0 none, 1 the web tests' GPS fix 147.235/-42.92), the web's hit count,
/// an FNV-1a-64 hash of its top 10 rows and its first name. A row hashes as
/// `name|type|meta|score %.4f|lat %.6f|lon %.6f|w,s,e,n %.6f or -|km %.4f or -`,
/// rows joined by "\n".
///
/// Regenerate after a deliberate ranking change, or when the data files are
/// rebuilt (the expectations are pinned to the 2026-09-12 pull): run the old
/// search.ts (`git show 04ea5d9:app/src/search.ts`, everything above
/// "// ---------- loading", imports dropped) under `node` over the same
/// queries with limit 30 and hash its rows the same way. 164 hand-picked
/// queries (×2 centres) cover every rule; 300 random ones (prefixes,
/// mid-word fragments, addresses in every unit/range/suffix form, number
/// words) were drawn from the data. All 3,224 cases of the full sweep
/// (incl. Hobart and Launceston centres) matched when this was written.
@Suite struct SearchParityTests {
    static let centres: [GeoPoint?] = [nil, SearchFixture.gps]

    @Test func matchesTheWebImplementation() throws {
        let idx = try SearchFixture.index()
        var failures: [String] = []
        let lines = Self.table.split(separator: "\n")
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let (q, centre, n, hash, firstName) = (f[0], Int(f[1])!, Int(f[2])!, f[3], f[4])
            let hits = idx.search(query: q, near: Self.centres[centre], limit: 30)
            let gotHash = Self.hex(Self.fnv1a(hits.prefix(10).map(Self.canonical).joined(separator: "\n")))
            if hits.count != n || gotHash != hash {
                failures.append("\"\(q)\" @\(centre): web \(n) hits, first \"\(firstName)\" — swift \(hits.count), first \"\(hits.first?.name ?? "")\"\n    " +
                                hits.prefix(5).map(Self.canonical).joined(separator: "\n    "))
            }
        }
        #expect(lines.count == 628)
        let report = "\(failures.count) of \(lines.count) differ:\n" + failures.prefix(10).joined(separator: "\n")
        #expect(failures.isEmpty, "\(report)")
    }

    static func canonical(_ h: SearchResult) -> String {
        let bb = h.bbox.map { b in [b.west, b.south, b.east, b.north].map { String(format: "%.6f", $0) }.joined(separator: ",") } ?? "-"
        let km = h.distanceKm.map { String(format: "%.4f", $0) } ?? "-"
        return "\(h.name)|\(h.type)|\(h.meta)|\(String(format: "%.4f", h.score))|" +
            "\(String(format: "%.6f", h.coordinate.latitude))|\(String(format: "%.6f", h.coordinate.longitude))|\(bb)|\(km)"
    }

    static func hex(_ v: UInt64) -> String { String(format: "%016llx", v) }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    @Test func hashMatchesTheGenerator() {
        // one row hashed by the Python generator
        let row = "Kunanyi / Mount Wellington|Mountain|Mountain · Wellington Park, Glenorchy|4.0000|-42.904640|147.224380|147.203060,-42.921810,147.245690,-42.886380|-"
        #expect(Self.hex(Self.fnv1a(row)) == "26aaa80e1e4831a9")
        #expect(Self.hex(1) == "0000000000000001")
    }

    // query \t centre \t web hit count \t hash of the top 10 \t first name
    static let table = """
kunanyi	0	1	26aaa80e1e4831a9	Kunanyi / Mount Wellington
kunanyi	1	1	6d9c3a4a298b4a43	Kunanyi / Mount Wellington
eliz st hob	0	3	f1b3242966bf314d	Elizabeth Street
eliz st hob	1	3	155ecae710f3a2f7	Elizabeth Street
mt wellington	0	17	9291aa26fdf710bf	Kunanyi / Mount Wellington
mt wellington	1	17	cf34fc06e55636e7	Kunanyi / Mount Wellington
sandy bay rd	0	18	9d579e0fbce139ce	Sandy Bay Road
sandy bay rd	1	18	90fe3f68733270c7	Sandy Bay Road
elizabeth st north hobart	0	1	3983d1b042dbf4d7	Elizabeth Street
elizabeth st north hobart	1	1	02be5134c0c3fdbf	Elizabeth Street
7 mile beach	0	30	c28fc37a9644d5c4	Seven Mile Beach
7 mile beach	1	30	a21e7562a43cf901	Seven Mile Beach
salamanca	0	9	344a3faba1cdeef7	Salamanca Square
salamanca	1	9	e597d79e6923d473	Salamanca Square
elizabeth street	0	28	a558f41fdf25a406	Elizabeth Street
elizabeth street	1	28	751fe650556b10a8	Elizabeth Street
12 elizabeth st hobart	0	4	c08ce785c26591b6	12 Elizabeth Street
12 elizabeth st hobart	1	4	1cc342a48596cd46	12 Elizabeth Street
henry jones	0	1	3ccdeb958e22756c	Henry Jones IXL Complex
henry jones	1	1	32f136d9c94ee29c	Henry Jones IXL Complex
hobart	0	30	0a92d0107e621431	Hobart
hobart	1	30	b01fd4af5b543bf5	Hobart
hobart rivulet	0	20	4ca7e958df8cff3f	Hobart Rivulet
hobart rivulet	1	20	ca5e751340ea00f4	Hobart Rivulet
sandy bay	0	30	a36f8a7cce6b1f7d	Sandy Bay
sandy bay	1	30	1fdc7d641b1456c5	Sandy Bay
eliz hob	0	7	97e134beb8d77608	Elizabeth Mall
eliz hob	1	7	28c9498cd94e1d31	Elizabeth Street
obriens rd	0	4	c75a7305f36ff624	O'Briens Road
obriens rd	1	4	07d82ff3542af076	O'Briens Road
o'briens	0	7	2675477f539bce2d	O'Briens Hill
o'briens	1	7	59307bf90e24d9f6	O'Briens Hill
dentrecasteaux	0	5	dcd98c6234152507	D'Entrecasteaux Channel
dentrecasteaux	1	5	d3f449d775906b51	D'Entrecasteaux Monument Historic Site
1/3 sandy bay rd	0	30	4f5cc744c1a8ff06	3 Sandy Bay Road
1/3 sandy bay rd	1	30	4eba6525f99b7f1c	3 Sandy Bay Road
3-5 sandy bay rd	0	30	4f5cc744c1a8ff06	3 Sandy Bay Road
3-5 sandy bay rd	1	30	4eba6525f99b7f1c	3 Sandy Bay Road
1 3 sandy bay rd	0	30	4f5cc744c1a8ff06	3 Sandy Bay Road
1 3 sandy bay rd	1	30	4eba6525f99b7f1c	3 Sandy Bay Road
elizabeth st new town	0	1	c34b896c0afab678	Elizabeth Street
elizabeth st new town	1	1	5a7bdb602b4ab655	Elizabeth Street
kunanyi hob	0	1	ea45f452f205903c	Kunanyi / Mount Wellington
kunanyi hob	1	1	57477cba5a6432f4	Kunanyi / Mount Wellington
3 sandy bay rd	0	30	4f5cc744c1a8ff06	3 Sandy Bay Road
3 sandy bay rd	1	30	4eba6525f99b7f1c	3 Sandy Bay Road
5 sandy bay rd	0	30	fdfd502b74414cdf	5 Sandy Bay Road
5 sandy bay rd	1	30	6a00589b616b564d	5 Sandy Bay Road
15a elizabeth st	0	30	6f1d1c89ad61ff12	15A Elizabeth Street
15a elizabeth st	1	30	79e74897b79e5890	15A Elizabeth Street
1/12 elizabeth st	0	30	b23d2afe684a2898	12 Elizabeth Street
1/12 elizabeth st	1	30	d91bcdb10227f545	12 Elizabeth Street
2-4 elizabeth st	0	30	d09c488ec494ed12	2 Elizabeth Street
2-4 elizabeth st	1	30	7a0bfc268d63e111	2 Elizabeth Street
1 12 elizabeth st	0	30	b23d2afe684a2898	12 Elizabeth Street
1 12 elizabeth st	1	30	d91bcdb10227f545	12 Elizabeth Street
12 elizabeth st	0	30	b23d2afe684a2898	12 Elizabeth Street
12 elizabeth st	1	30	d91bcdb10227f545	12 Elizabeth Street
12	0	5	c2057507be1ffe8f	12 Oaks
12	1	5	a4587601dfc5428a	12 Oaks
sa	0	30	cc7209d9bd92fd2f	Sabbath Creek
sa	1	30	0135d27164d2f143	Sandy Bay Rivulet
st	0	30	626d94615dca8a84	St Albans Court
st	1	30	d63aa4b982eeba86	St Georges Terrace
mt	0	30	83949aa454cda046	Mount Achilles
mt	1	30	2794b907841f565f	Mount Arthur
ellington	0	30	b2b996a76c3a0a09	Ellington Road
ellington	1	30	ec1bb75d522a71bd	Ellington Road
cradle mountain	0	30	4b742e5439d9fb5f	Cradle Mountain
cradle mountain	1	30	9807201b2351e0be	Cradle Mountain
lake st clair	0	30	082ac987e6b22188	Lake St Clair
lake st clair	1	30	e610cfdb6148fe59	Lake St Clair
saint helens	0	30	281f2818cb4bb05b	St Helens
saint helens	1	30	e05a3de6d53f18c1	St Helens
st helens	0	30	e8aa4653cba58196	St Helens
st helens	1	30	c553b56745dd1c73	St Helens
pt arthur	0	22	9cea277235e4e4cf	Point Puer
pt arthur	1	22	f75cd753b6c357d1	Point Puer
port arthur	0	30	7075e2af36ad1153	Port Arthur
port arthur	1	30	3dc81c2e984133ba	Port Arthur
freycinet	0	30	936f78164eb9936f	Freycinet
freycinet	1	30	d55e8ad28d9fad23	Freycinet
wineglass bay	0	5	fe0c19ef4fcc0f59	Wineglass Bay
wineglass bay	1	5	00b1623bd58bddec	Wineglass Bay
russell falls	0	5	47cea63e16b9b7c0	Russell Falls
russell falls	1	5	17f17cb5581a39d5	Russell Falls
mt field	0	30	ae6df3b2e19638cd	Mount Field
mt field	1	30	fb70ccbf99840c96	Mount Field
bruny	0	30	d757694bb0b7ab09	Bruny Island
bruny	1	30	5f1c5156f3ae4ff9	Bruny Island Neck Game Reserve
macquarie st	0	11	77936313f52d03e9	Macquarie Street
macquarie st	1	11	12a6f628757f6e81	Macquarie Street
murray st	0	15	90c16c7975d0fcd3	Murray Street
murray st	1	15	ffcee6d8b2867823	Murray Street
liverpool st hobart	0	2	1d49251eaed0a44d	Liverpool Street
liverpool st hobart	1	2	e0b6d143f931eefb	Liverpool Street
brisbane st launceston	0	3	367d25debd2d2dec	Brisbane Street
brisbane st launceston	1	3	76c893f273e5a28b	Brisbane Street West
charles st	0	30	0080cab10386e5b8	Charles Street
charles st	1	30	37e772998ec51365	Charles Street
1 charles st launceston	0	6	d4368ac38d026daf	1 Charles Street South
1 charles st launceston	1	6	12e3a5b653eaf047	1 Charles Street South
100 macquarie st	0	18	7e518329a626c707	100 Macquarie Street
100 macquarie st	1	18	5d629832de8bbbd8	100 Macquarie Street
highway	0	21	ce143db790d8d911	Arthur Highway
highway	1	21	adfc99a1ceab499c	Domain Highway
midland hwy	0	4	3c15e78be4a79ba7	Midland Highway
midland hwy	1	4	2d0b963a56e1ca61	Midland Highway
tasman hwy	0	3	04454023aef86fbc	Tasman Highway
tasman hwy	1	3	ae68106d98351a8b	Tasman Highway
huon	0	30	b9f42c9fe6114dae	Huon Basin
huon	1	30	7f75237c7fbbefd1	Huon Gully
geeveston	0	30	c3ffec8658f35e32	Geeveston
geeveston	1	30	926178620363120b	Geeveston
stanley	0	30	dbe88554d89b5ccb	Stanley
stanley	1	30	bbf324ee70d34e7a	Stanley
the nut	0	4	8a5eb5c84b63348a	The Nut
the nut	1	4	efaf561660fb501b	The Nut
strahan	0	30	bfad446bbf8dab6c	Strahan
strahan	1	30	e1823f0d12c18991	Strahan
queenstown	0	30	0dad8201e6a9ba3b	Queenstown
queenstown	1	30	568aec68486a4f66	Queenstown
nth hobart	0	30	4c00a0a038d8260d	North Hobart
nth hobart	1	30	b9487f93ae7fbf9d	North Hobart
sth arm	0	30	1073830bd7827599	South Arm
sth arm	1	30	e8fc44d9803bd45b	South Arm
blackmans bay	0	30	4d112e635b7d8192	Blackmans Bay
blackmans bay	1	30	f88d92fef270d88b	Blackmans Bay
kingston beach	0	30	c443f0b7da84f9e4	Kingston Beach
kingston beach	1	30	49f340744b880f9a	Kingston Beach
richmond	0	30	69fe07d99d651bd4	Richmond
richmond	1	30	a3499686e7b6256f	Richmond
oatlands	0	30	6740539b0c7df5b3	Oatlands
oatlands	1	30	20d8c5e8d0332e89	Oatlands
ross	0	30	8065fe9bded6344d	Ross
ross	1	30	968e3065390dae03	Ross
campbell town	0	30	8bcafa1e212bc7ae	Campbell Town
campbell town	1	30	f932fe78fc183fcc	Campbell Town
bicheno	0	30	dd5b428363ae9f2a	Bicheno
bicheno	1	30	a5bdd61593f001c8	Bicheno
swansea	0	30	7882a921860d860c	Swansea
swansea	1	30	8cf0a1fae545c726	Swansea
swan	0	30	aca733a0ab7ee993	Swan Basin
swan	1	30	1f1f23e32e33112e	Swan Park
tamar	0	30	eaea9136f7c6f4bd	Tamar Conservation Area
tamar	1	30	285cdc94de2e948d	Tamar Cut
west tamar hwy	0	2	8e2cb9890c5cb795	West Tamar Highway
west tamar hwy	1	2	e455a4a422d57083	West Tamar Highway
battery point	0	30	fa8b641297aca33d	Battery Point
battery point	1	30	930c2eb57aa888a0	Battery Point
arthur circus	0	1	0856b56d4b640d36	Arthur Circus
arthur circus	1	1	09c483913bee4629	Arthur Circus
constitution dock	0	1	6e0182fb3fd01ea9	Constitution Dock
constitution dock	1	1	e362559f5e1e0651	Constitution Dock
mona	0	30	21ef5876c008df9d	Mona Vale Saltpan
mona	1	30	aff1be6713687c11	Mona Vale Saltpan
cascade	0	28	bcb3f4bba0ad30d8	Cascade Creek
cascade	1	28	4b810a285eb6cc13	Cascade Gardens
mount nelson	0	30	a378b75aa84a56c6	Mount Nelson
mount nelson	1	30	dee293046358f182	Mount Nelson
taroona	0	30	da6f9a5e6b13c2ed	Taroona
taroona	1	30	57bd6ef1469b61dc	Taroona
margate	0	30	9be0d5af338cdc4b	Margate
margate	1	30	63dbe00a1732050b	Margate
snug	0	30	7bc2729bd4135618	Snug
snug	1	30	32081240f9cdf007	Snug
cygnet	0	30	184b82e8592e65c8	Cygnet
cygnet	1	30	ec67bbf448110a39	Cygnet
dover	0	30	db508b2d571e1065	Dover
dover	1	30	efe77c36735a0814	Dover
hastings caves	0	3	0b9ca42cfc2410b4	Hastings Caves
hastings caves	1	3	f70964770ef172ed	Hastings Caves
maria island	0	30	5780a8208f60df3f	Maria Island
maria island	1	30	974cdf66edd3b7aa	Maria Island
flinders island	0	30	66a6ff02fc5604a7	Flinders Island
flinders island	1	30	f7fbd09646456090	Flinders Island
king island	0	30	e9d0f769ff478e1a	King Island
king island	1	30	e2fdfdc7a82b076e	King Island
three hummock	0	2	8eddabc389cbdcfc	Three Hummock Island
three hummock	1	2	e8c69a108c586dcd	Three Hummock Island State Reserve
10 mile	0	30	fd21d18c825199fc	10 Four Mile Creek Road
10 mile	1	30	81a9755f52328188	10 Seven Mile Beach Road
ten mile	0	5	a8986f49f7c3ef3a	Ten Mile Creek
ten mile	1	5	6030a9063e9c525e	Ten Mile Hill
twelve	0	7	e3256896b65558f8	Twelve Hour Point
twelve	1	7	44942c2e4375576a	Twelve O'Clock Hill
2 2	0	24	0e87d2ec855c94cc	Brumbys Weir 2
2 2	1	24	6c4fd02c1d1804f9	Penstock Levee 2
aa	0	2	cd80b0064b05f3e2	Aarons Creek
aa	1	2	55fe5d158c524a96	Aarons Creek
zz	0	0	cbf29ce484222325	
zz	1	0	cbf29ce484222325	
xq	0	0	cbf29ce484222325	
xq	1	0	cbf29ce484222325	
ringarooma	0	30	409b0f6dcc4afb50	Ringarooma
ringarooma	1	30	79f89cf5bb32cabd	Ringarooma
wellington	0	30	4353ffdf6e140047	Wellington Creek
wellington	1	30	cacf202bfceec107	Wellington Falls
eaglehawk neck	0	30	031c6d25643ef80a	Eaglehawk Neck
eaglehawk neck	1	30	2e6aa4da61144195	Eaglehawk Neck
doo town	0	1	97ce0a49078bf6aa	Doo Town
doo town	1	1	c801cd358d828fc4	Doo Town
nubeena	0	30	2fdc731014705fc9	Nubeena
nubeena	1	30	7a6438eebb959b78	Nubeena
tce	0	30	d6a656a7f51a3b1f	Adina Terrace
tce	1	30	900e96a8afebad1a	Knocklofty Terrace
pde	0	30	734fa869ced118c6	Allotment Parade
pde	1	30	7c1de72ec7e7a127	Susan Parade
esp	0	30	9cb9de03c42e9890	Esperance Coast Road
esp	1	30	8a2f58c52ef98e17	Esplanade
huon hwy 20	0	20	8f3b21e0614aef5a	Huon Highway
huon hwy 20	1	20	0e49cc2f20886315	Huon Highway
elizabeth st 12	0	30	b23d2afe684a2898	12 Elizabeth Street
elizabeth st 12	1	30	d91bcdb10227f545	12 Elizabeth Street
sandy bay road 3	0	30	4f5cc744c1a8ff06	3 Sandy Bay Road
sandy bay road 3	1	30	4eba6525f99b7f1c	3 Sandy Bay Road
salamanca pl	0	1	0ff8f4ebbb59724e	Salamanca Place
salamanca pl	1	1	06c06415a392519d	Salamanca Place
salamanca place	0	1	c7fca08b720aede7	Salamanca Place
salamanca place	1	1	370c954cf6aa4022	Salamanca Place
69 salamanca pl	0	3	b6f3f4231fa22112	69 Salamanca Place
69 salamanca pl	1	3	245f2c0803288cfa	69 Salamanca Place
university	0	8	c497fe0b4e124575	University Oval
university	1	8	395e535eb9ab2462	University Sports Grounds
utas	0	1	94a6924f82778765	UTAS
utas	1	1	1f842ff2cdbd11ce	UTAS
hospital	0	29	6380baabe0fecc8e	Hospital Bay
hospital	1	29	10a66080818e91cc	Hospital Bay
royal hobart hospital	0	2	1b41809cd903b6e9	Royal Hobart Hospital
royal hobart hospital	1	2	c05907efd3cc9de0	Royal Hobart Hospital
airport	0	13	40875fc5c96ee824	Airport Crescent
airport	1	13	4e3ec61655818baf	Airport Crescent
hobart airport	0	2	d7e7799ebd86617a	Hobart Airport
hobart airport	1	2	1902eb3fd1af6aa8	Hobart Airport
scout hall	0	23	fe3c8f0e72104860	10th Hobart Scout Hall
scout hall	1	23	e8c948d713864a95	10th Hobart Scout Hall
golf	0	30	d0ed636c30604fa7	Allison Golf Course
golf	1	30	5d6e010f59f06093	Kingston Beach Golf Course
beach rd	0	30	aceb0ef8e002e031	Beach Road
beach rd	1	30	facf69c318f4106c	Beach Road
creek rd	0	30	923fa91ff0e94a5e	Creek Road
creek rd	1	30	55757d8584e9bede	Creek Road
main rd	0	30	105ca4b4d19f2a45	Main Road
main rd	1	30	35ec6eb75c7a7d3a	Main Road
main road	0	30	105ca4b4d19f2a45	Main Road
main road	1	30	35ec6eb75c7a7d3a	Main Road
1599	0	0	cbf29ce484222325	
1599	1	0	cbf29ce484222325	
Saint-Mary’s Créek	0	14	7265757f96888581	St Patricks Creek
Saint-Mary’s Créek	1	14	50b83e2ed2db05cd	St Patricks Creek
st marys	0	30	f886d0ee9bc0e3e2	St Marys
st marys	1	30	9283ffc6e5fd6fca	St Marys
D'Entrecasteaux Channel	0	1	3e139fb74ef6f487	D'Entrecasteaux Channel
D'Entrecasteaux Channel	1	1	862f720340747a58	D'Entrecasteaux Channel
Montagu	0	30	69da90955fdea792	Montagu
Montagu	1	30	a9c0a7f0286598e8	Montagu
montague	0	3	419a76cadcb44746	Montague Park Avenue
montague	1	3	7fa9008a1e40dcea	Montague Park Avenue
coles bay	0	30	601a9a215f72ac90	Coles Bay
coles bay	1	30	955a10d471aedc6c	Coles Bay
lime bay	0	5	46a9cbada2339912	Lime Bay
lime bay	1	5	687db05d38fca66c	Lime Bay
tunbridge	0	30	58f2d2dfdd56328a	Tunbridge
tunbridge	1	30	5c579160d4e9754a	Tunbridge
bothwell	0	30	3f3c8683c0b5bd03	Bothwell
bothwell	1	30	0eb38f49b2368dd2	Bothwell
lake	0	30	4f221127d9706d0b	Lake Ada
lake	1	30	ece973c94b4c8139	Lake Denison
river derwent	0	30	6d9e792d0d6a77cb	River Derwent
river derwent	1	30	efc4d53b6cc3995b	River Derwent
derwent	0	30	70f9eb5628bb63f1	Derwent Basin
derwent	1	30	d513c0dcf4ed1c71	Derwent Park
mt wellington rd	0	0	cbf29ce484222325	
mt wellington rd	1	0	cbf29ce484222325	
pinnacle rd	0	3	984b3dda9a3983cf	Pinnacle Road
pinnacle rd	1	3	621448989fd56b06	Pinnacle Road
pinnacle road	0	1	9d9bdc35a2f1212b	Pinnacle Road
pinnacle road	1	1	9c7d3fda96ace758	Pinnacle Road
fern tree	0	30	d4ae5ee477ff85fb	Fern Tree
fern tree	1	30	67e7de1424d05a8f	Fern Tree
ferntree	0	5	230e7f40ae907555	Ferntree Falls
ferntree	1	5	a37f98af1f42812f	Ferntree Glen Creek
1 pinnacle rd	0	4	273d0594afd26ba2	Pinnacle Road
1 pinnacle rd	1	4	4b2b1d159f49df55	Pinnacle Road
the springs	0	5	0354f887d792d6b6	The Springs
the springs	1	5	5603f53708e720aa	The Springs
organ pipes	0	2	652be78f2ac047e6	Organ Pipes
organ pipes	1	2	1b4d39a202d9339d	Organ Pipes
sleeping beauty	0	2	caa78c39d58c4697	Sleeping Beauty
sleeping beauty	1	2	a0d67f79fd70bf10	Sleeping Beauty
collinsvale	0	30	1aa8aff6462d9094	Collinsvale
collinsvale	1	30	d28622d400029c1a	Collinsvale
glenorchy	0	30	ece51c0d16365c96	Glenorchy
glenorchy	1	30	6c5bc28318dca347	Glenorchy
moonah	0	30	f7242c43514bface	Moonah
moonah	1	30	397908ef87684e09	Moonah
new town	0	30	3b6a0cd82896b5e5	New Town
new town	1	30	6bee743e2c256526	New Town
lenah valley	0	30	ed5f43156f56d34e	Lenah Valley
lenah valley	1	30	b4fbb0ee5695bc4b	Lenah Valley
claremont	0	30	a24da5a3a379adfc	Claremont
claremont	1	30	d717f7b262272356	Claremont
bridgewater	0	30	7ff3a59b94254f6f	Bridgewater
bridgewater	1	30	eea61920cb2b712b	Bridgewater
brighton	0	30	0ff6d4cea5f92edf	Brighton
brighton	1	30	775218352eba2b30	Brighton
old beach	0	30	903811277de6ce0f	Old Beach
old beach	1	30	a4d7217823d8b8a3	Old Beach
rokeby	0	30	a62b9ab46a542a06	Rokeby
rokeby	1	30	96ac657f010da152	Rokeby
howrah	0	30	7f81cc9e938d53f4	Howrah
howrah	1	30	a1e01395a5503325	Howrah
bellerive	0	30	2c9373681f465c75	Bellerive
bellerive	1	30	7ee5396331200b64	Bellerive
lindisfarne	0	30	02a489a35b74fcd4	Lindisfarne
lindisfarne	1	30	b623e0bd5c3cbcef	Lindisfarne
rosny	0	30	c70d4923bc649fcb	Rosny
rosny	1	30	6503711ac13ba313	Rosny
sorell	0	30	1e7ce3db8bc605d2	Sorell
sorell	1	30	a83e08a076d521d0	Sorell
dodges ferry	0	30	6c96483ae100e8ed	Dodges Ferry
dodges ferry	1	30	fbd174c863975f99	Dodges Ferry
carlton	0	30	2837a4eddeaf615d	Carlton
carlton	1	30	6efbd588becbe06c	Carlton
primrose sands	0	30	33c88afcbbe053e6	Primrose Sands
primrose sands	1	30	98d56fa227cc1ba7	Primrose Sands
dunalley	0	30	00e55f010ea34dec	Dunalley
dunalley	1	30	3911c7a7e7a273a4	Dunalley
 Ce	1	30	f9014241d0527ecd	Cerberus Plain
 Cree	1	30	d751938b118f558b	Creeses Mistake
 Hous	1	30	bbac1bb42747ea0d	House Rocks
 Pla	1	30	3f62f6813167ce89	Plains Rivulet
 Place	1	30	62ecd34619b1e14f	Stephenson Place
 St	1	30	d63aa4b982eeba86	St Georges Terrace
 Vale	1	30	f8f3b1e4ebc8306e	Vale of Rasselas
1 4 Krushka Street	1	2	a24c6b9d126edc86	4 Krushka Street
1 Sophie Court Coles Bay	1	2	4556340f47944bd7	1 Sophie Court
1 Tara St	1	18	bb3b923f4901a178	1 Tara Street
1 mile creek	1	30	23126c030e6112e9	1 Four Mile Creek Road
1 road	1	30	804c62d637b44dee	1 Westringa Road
10 road	1	30	3b2a5be4883e03be	10 Grays Road
106A Giblin Street	1	12	e9e1d5ecaa31e9e4	106A Giblin Street
11 mile	1	30	e6c0e0dd6c53ab83	11 Seven Mile Beach Road
11 mile creek	1	30	20b7c5b6835fb861	11 Four Mile Creek Road
11 road	1	30	f66a8d6de16ae12d	Eleven Road
11 sisters	1	30	08f11602d59acdf0	11 Sisters Beach Road
11-207 Oxford Crescent	1	2	82de7259ea7a876c	11 Oxford Crescent
11-55 Walter Street	1	8	af7c3a6f84e9457a	11 Walter Street
110 Willis Road	1	6	25763cb63d218b29	110 Willis Road
1100 Dairy Plains Ro	1	10	3ac5f7a332bbb224	1100 Dairy Plains Road
125 Oak Dene Road	1	3	791bd4f4c40378e4	Oak Dene Road
127A Outram Street Summerhill	1	2	2753aa50b8e1008a	127A Outram Street
13 Shaw St	1	21	d250f42cef9f1318	13 Shaw Street
13 mile	1	30	22179c23647748d9	13 Seven Mile Beach Road
13 sisters	1	30	86f2cb2ac37b45cb	13 Sisters Beach Road
14 Crooked Tree Court	1	2	f027731e005893db	14 Crooked Tree Court
14 Haven Drive	1	13	15286106235346ff	14 Haven Drive
14 Veronica Street Primrose Sands	1	2	5616eb647d2106cc	14 Veronica Street
144 Hurdle Road	1	2	cfe8cce3f271fd7d	144 Hurdle Road
15 Darleymore Lane	1	2	63734cf9814dde57	15 Darleymore Lane
16 mile	1	30	c5d5c6a8f2417ab5	16 Seven Mile Beach Road
16 mile beach	1	30	b31002ccadd00f81	16 Seven Mile Beach Road
16 mile creek	1	30	916ac4a524811640	16 Four Mile Creek Road
16-285 Lichan Place	1	2	f2ea200ee210e377	16 Lichan Place
1635 Montagu Road Montagu	1	30	f6084497e4be0b4e	1635 Montagu Road
16801 Midland Highway	1	24	cdcc88613bb7460a	16801 Midland Highway
17 Walker Street St Helens	1	2	27c127443daee1c4	17 Walker Street
17-225 Grenville Street	1	2	924c178ccfbda8aa	17 Grenville Street
17-279 Peel Street	1	9	9b94194c3c04bdfa	17 Peel Street
18 Virginia Court Sandy Bay	1	2	88db9398e4980fbd	18 Virginia Court
1B Bignell St	1	2	6950aca88b97633e	1B Bignell Street
2 3 Ginseng Court	1	2	274b60fc86f67ad5	3 Ginseng Court
2-257 Ferndene Avenue	1	2	f89b9f845d9fb618	2 Ferndene Avenue
2-34 Rose Avenue	1	14	d46ad5cf6343087e	2 Rose Avenue
20 Clydesdale Avenue Glenorchy	1	2	1efe54758f58a336	20 Clydesdale Avenue
24458-26 Lyell Highway	1	17	6b38158858fa093c	24458 Lyell Highway
248 Milldam Road	1	3	50ac5f60ccf6dcc1	Milldam Road
28 Lily Street	1	2	9bbd7be810e93d9e	28 Lily Street
280 Kendall Street	1	2	82f585da35f0d451	Kendall Street
292 Coburn Lane	1	2	5e8340447b4c452b	Coburn Lane
3 10 Buchanan Avenue	1	2	4443390a8885ed48	10 Buchanan Avenue
3 Mary Street Perth	1	2	167a33003e3d8772	3 Mary Street
30 Esplanade No	1	9	d728b45fc519a125	30 Esplanade North
31 Montagu Street Lenah Valley	1	1	542be74402137000	31 Montagu Street
31 Shaw Street Swansea	1	2	f04ed17c87e63f64	31 Shaw Street
310 Exhibition Link	1	2	b31b786dccbed06b	Exhibition Link
313 Claremont Link Road	1	2	e5b1e27c6aeb010f	Claremont Link Road
32-125 Jermyn Street	1	2	56fd997126449636	32 Jermyn Street
33 Eiszeles Road Lachlan	1	2	e447f9fbbbeca86e	33 Eiszeles Road
33 Harry Place	1	2	cecba20770e178eb	33 Harry Place
33 Pothana Ro	1	2	b19647c5a04d2c3a	33 Pothana Road
334 Strathern Street	1	2	a16b7cf3ffc88cdb	Strathern Street
348 Gumbowie Drive	1	2	46a01db6dc5b558d	Gumbowie Drive
35 Akers Street Latrobe	1	2	a1181a0d6da835d2	35 Akers Street
35 Moores Road	1	7	ab03233cae75fae9	35 Moores Road
365 Dip Road	1	9	9c5d04194689a97b	Dip Road
371 Rice Street	1	4	91793297843130e9	Rice Street
376 Whittons Road	1	3	9e5fa9f686a47df7	Whittons Road
386 Topham Street	1	2	cb88a4a51de1fee0	Topham Street
39 Honeymoon Point Road The Gardens	1	2	fb50210b56fc62a2	39 Honeymoon Point Road
3A Pelham St	1	3	bd40d4ae45e7a43a	3A Pelham Street
4 Gee Avenue	1	2	cc5f51d353a30cd2	4 Gee Avenue
47 Calder Crescent	1	2	ffc1748a5eae7d84	47 Calder Crescent
477-170 Cemetery Road	1	30	380670bc7aca3c7d	477 Cemetery Road
5 hummock	1	11	ec687a6e2afd6b91	Hummock Saddle
5 pound	1	4	4f83fc666129562e	5 Pound Road
5/2 Medlar Street	1	2	8dcf303a136e51c3	2 Medlar Street
50 sisters	1	30	96808cbde4ed27a7	50 Sisters Lane
6 1 Alice Street	1	8	bae67ab5497958f1	1 Alice Street
6 93 Margaret Street	1	14	2b0a67aeca1250f0	93 Margaret Street
6 Kastoria Court	1	2	10a2e26b292c8fd9	6 Kastoria Court
6/41 Gettington Road	1	2	52b1be5f4902739e	41 Gettington Road
6/6 Sutton Court	1	4	51e82767c93c9471	6 Sutton Court
6107 High St	1	30	a81a57c202a00992	6107 High Street
69-173 Wilsonia Road	1	2	96f231da02fe7e4f	69 Wilsonia Road
7 3 Diamond Waters Rise	1	2	0ee2e666968031e9	3 Diamond Waters Rise
7 Cabernet Co	1	2	82c11af1a73b9927	7 Cabernet Court
7 Christopher St	1	8	111b0c53cf3343b3	7 Christopher Street
7 Hardys Court	1	2	707cf63a9d9c93e4	7 Hardys Court
7-89 Congress Street	1	2	9c3d0c0189b0217f	7 Congress Street
7/10 Fuller Street	1	2	d4c0703dd0a85575	10 Fuller Street
7/20 Batts Road	1	2	93a38df4b74b1608	20 Batts Road
8/6 Edward Street	1	30	fddb3acea257880c	6 Edward Street
9/15 Westwind Drive	1	2	09c51a2bca8d025d	15 Westwind Drive
9/20 Den Road	1	30	0a90d88f6b84703a	20 Den Road
93-266 Salamanca Place	1	3	f1ed6b583a24eb74	93 Salamanca Place
A B	1	30	c2026a6b3dcfa0be	A B C Creek
Abe Co	1	24	318b1c67bf5cc1b7	Abel Court
Ains	1	30	065e5131f5910966	Ainslie Beach
Alexander Street 2	1	17	13f0dceadb980707	2 Alexander Street
Arl	1	30	3335c425ea958507	Arlunya Street
Ba Laun	1	30	48f700f8a31f926c	Bailey Hill
Bacala Roa	1	2	0f65be19d2bdda0d	Bacala Road
Bayview Hou B&	1	1	0936d09ebb21f74f	Bayview House B&B
Berry He Sout	1	1	93207e69b6ea8fc3	Berry Head
Bi Brad	1	3	76bc45f9f48476c9	Binney Dam
Billanb Court	1	1	87c78eb06817b4d8	Billanbri Court
Bish	1	30	54052653ea7f4507	Bishton Creek
Blac Jac Bigh	1	1	f96878b87f4f034f	Black Jack Bight
Blac Lookout Wate	1	1	af11107a2c5a7354	Blackmans Lookout
Bohemia St M	1	2	1a34546cadbb411c	Bohemia
Bra	1	30	3b087ac439d71e6b	Brains Hill
Bridpor	1	30	b78744190d477605	Bridport
Brun Is	1	16	5e1e0bded4d9b4c9	Bruny Island Neck Game Reserve
C8 Pate	1	2	c3b7b49b94b0f9d3	C854
Campb Rivulet West	1	1	e1d30678913577b3	Campbell Rivulet
Casuarina Drive 3	1	2	29d62be6ac6fdc4d	3 Casuarina Drive
Cav	1	30	a4f4fc1a75d07d3f	Caves Hill
Cay Le	1	1	f1ac54a77fb0fd79	Cay Lea
Chink Point	1	1	d2105c56d8c6c0cd	Chink Point
Clar	1	30	45b295ee3b45b485	Clare Street Sports Ground
Cle Lagoon	1	7	3d34af1ec6d20713	Clear Lagoon
Clinton Road 98	1	2	b01ddd0e9ad932e9	98 Clinton Road
Co	1	30	257189d2dc7ad791	Combes Rivulet
Cooks Lane	1	2	8e7b8bf1dbedb625	Cooks Lane
Cre	1	30	45e998ed0dec3eda	Cremorne
Cri	1	30	28a83ba3ee73cfbb	Cris Fitzpatrick Community Park
Cro River Sout	1	3	54cdde5103e60375	Crossing River
De Derb	1	30	08e04c1aa7566509	Derbyshire Rocks
Dewdrop Court 2	1	2	dde6b9691bb7dd0a	2 Dewdrop Court
Donal Av	1	2	9607df930861d8f0	Donalds Avenue
Downie Street 13	1	4	742202dc57865649	13 Downie Street
Ea Roc Lag	1	2	e3368ce8aa55e5d2	East Rocky Lagoon
Eastb	1	5	348fa2dcac0f67b2	Eastbourne Sugarloaf
Ellensw	1	1	fb6a05da4a62b2d4	Ellenswood
Esk Main Road 1487	1	5	f897216dbd0456c3	1487 Esk Main Road
Esthe Stre	1	1	dc35be2974c6c9f2	Esther Street
Ev Crescent	1	7	79d2adfd92499ef8	Evelyn Crescent
Far Point	1	6	4ac09bee57e9222f	Farrell Point
Fawkner Street 8A	1	2	fd9f43f9c1ad2307	8A Fawkner Street
Fox Cole	1	3	d16ab71b309a1802	Foxs Creek
Gard	1	30	2630574e9a92bc5c	Gard Place
Geor	1	30	79d23b406b2df091	Georges Flagland
George Tow	1	30	5c23e3a9ee435a73	George Town Golf Course
Gilham Street 4	1	2	36cc312dce453b9f	4 Gilham Street
Gl	1	30	9f86adc96cd8d612	Glenrose Park
Gorm Gorm	1	30	9f0e09191b2a00d2	Gormley Park
Gre Crays	1	1	a6f15c4b614cf912	Grey Crays
Green Bell	1	1	294e3f011b2b7bd1	Green Gates
Ha Roa	1	30	fbdb19b06c370ef6	Hamilton Road
Ham	1	30	412427b7a2adc938	St Michaels Collegiate Ham Common Sports Ground
Har	1	30	35b996a0e82c0238	Hartam Rivulet
Have	1	30	3fce16f5c6039d5c	Haven Lake
Hen Plains	1	2	42c6c058c058d579	Henrietta Plains
Hig Histori Si	1	1	4c7b961a8b1c3ecd	Highfield Historic Site
Home Nuna	1	1	1248c76595db6e8b	Homebush
Huonvil	1	30	85d94ac34df8320f	Huonville
In Street Wyny	1	2	efbfd43711dbcaea	Inglis Street
Ingo	1	8	3556d9d4da22e2c8	Ingola Street
Iona Rave	1	1	76d99ab3e451fce8	Iona Court
Ja	1	30	88e21568826a3381	Jacques Creek
Jo Str King	1	2	8e5ff2923c74e7fa	John Street
Kanangr Brig	1	1	16f752685288a237	Kanangra Court
Karumb Pres	1	1	8495fabe600e7079	Karumba
Knopwo Hill Natur	1	1	c16929983a64c594	Knopwood Hill Nature Recreation Area
Koh-i- Ro	1	1	48795450a0f43aa4	Koh-i-Noor Rock
Kru	1	8	a3ebc571c092f577	Kruses Creek
Lad Barron Fi Statio Lady	1	1	6f7f9269765d2564	Lady Barron Fire Station
Lia	1	30	51242151d1695ae2	Liapootah Power Station
Light Stree Curr	1	1	82745ebc19b126d4	Lighthouse Street
Longfo	1	30	6cdf59de7f8dd3c8	Longford East Base
Lucas	1	30	548d629b5ce1a961	Lucas Point
Man &	1	30	71bf1d08b3e41916	Man O'War Jack
Mareng	1	3	cdaf7e23a061b379	Marengo Creek
Me Ro Dee	1	1	2793e3061f15053f	Mentmore Road
Mil	1	30	77ea2bb654d3368b	Millhouse Falls
Minerv Dri	1	1	2f491fa08e020b38	Minerva Drive
Minerv Park	1	1	21fbe9c387c207b5	Minerva Park
Mo Op	1	2	20f478db13fc2773	Mount Ophel
Mun Ba	1	14	9d8bd6008f988f23	Munro Bay
Myall Station	1	1	4a187a3e0c305f67	Myalla Station Road
Ne	1	30	8795e4b4ad316b9d	Neika
Negara Street 3	1	2	2df8fb4465e40cc6	3 Negara Street
Non Par Crad	1	1	efc4fb4b62af50bb	Nonsuch Park
Oak Ba	1	8	30d1db5ff792a5cc	She Oak Bank
Olympi	1	4	ad247545c9ccbb4b	New Norfolk Olympic Pool
Picni	1	29	88d1308383fcc7ff	Picnic Cove
Pin Fo	1	10	338bee356d3efe0b	Pine Forest Moor
Plac	1	30	ca0d36aef2c2dda1	Mathers Place
Poa Golf Course	1	1	90a9875651bb955e	Poatina Golf Course
Police Point Road 155	1	8	220ecda9e0172a47	155 Police Point Road
Pomona Road North 136	1	2	b165b7711556f9ad	136 Pomona Road North
Pott Gard	1	1	4a22f99b4ac9269e	Pottery Road
Prim Sand Gene Stor	1	1	700a77cd12ec131a	Primrose Sands General Store
Ra Isl 	1	30	9381e41c60cd759a	Rabbit Island
Railway Court 6	1	2	3f53dca837a6eaca	6 Railway Court
Re Ci	1	30	ffb9f261f0796c46	Renfrew Circle
Ridgl	1	30	d2d5b138cb15b32e	Ridgley
Rise	1	30	9eb7037384fb8c53	Montrivale Rise
Roa	1	30	a727bd73d917dc24	Roaring Creek
Rock Lily	1	3	ca3e3490c88e1179	Rock Lily Way
Rou Hill	1	27	80017bba04d92031	Round Hill
S Gla	1	30	3d7906e823cffc5d	Spriggs Flat
Sad	1	30	0af3ecf627c7acc0	Sadgrove Point
Sampso Str Hill	1	1	283399977089d6f8	Sampson Street
Sarr	1	1	488cc9c3a6b85683	Sarron Place
Shell 	1	30	dcfd35e81c7a6c62	Shell Creek
St Georg Spor Gr Long	1	1	c2f650d31a926dd7	St George Sports Ground
Strath West	1	5	ae95bc34df263078	Strathallan
Street	1	30	68b604b40c371e83	Tagg Street
Tacky Cre Camp	1	1	4fc204d1a49319db	Tacky Creek
The Sout	1	30	4b8da3043a909e31	The Slides
Tho Cr	1	25	a42cdc6b71470aa8	Thompson Crescent
Tomahawk Road 141	1	7	9d9110732f0fd6e3	141 Tomahawk Road
Tulla Tull	1	30	00e7c93eec99fc8c	Tullah
Tye Tyen	1	24	09aa393be41b0e29	Tyenna River
Urana	1	1	fa8f03b637dac81f	Urana Court
Wall Fran	1	2	70c607843fce8a7d	Wallaby Creek
Wate	1	30	a7b4538feada3ea4	Waterworks Reservoirs
Weaning West	1	1	9c811858e4431899	Weaning Road
Weedings	1	5	25dd38163a9d410c	Weedings Hill
Weel Cree	1	1	5418f0446b0b9dcb	Weelaty Creek
Wellingt	1	30	e0aab9fdc055d0e9	Wellington Falls
Whitemor Uniti	1	2	5ece2ccb7d92c106	Whitemore Uniting Church Cemetery
Wilc	1	2	cfa9141268bf2969	Wilcox Creek
Wilso	1	30	a4c6d103e8adf189	Wilson Park
a Mill	1	30	05e71898beb13b6c	Goods Mill Creek
ao	1	2	8fb9c2a8d0916e91	Aotea Road
aring	1	30	417706713d8b5243	Aringa
arrabe	1	3	c6e7a8480c6a4f04	Yarrabee
ater	1	30	6aa881c89eb83fd1	Waterworks Road
ba	1	30	289b683ef0cb9cbf	Badger Hill
bo	1	30	e0fdf6a86cd5ebfd	Boddys Creek
coa	1	30	33c3795356c08418	Coal River
daihi 	1	2	b4bc883966e20da9	Adaihi Nursing Home
e Fore	1	30	f57fdd737c539605	Echo Forebay
e Pr	1	29	2cc9566988c83ecc	Pretty End
eac	1	30	a7f69954feb572ef	Peace Park
eauli	1	1	59d02ffcbb9a77c9	Beaulieu Street
eet Re	1	30	2e69eca419c6c8bb	Tagg Street
els	1	30	9360feca3d92ee5a	Nowhere Else
erlea	1	19	74f813c834b6a766	Summerleas
eserv	1	30	4fef982ee28a8486	Reservoir Trail
fa	1	30	c1eb8b6cb58096b4	Fawcett Rivulet
gess 	1	21	d830b9fa40b1b301	Burgess Avenue
ghcrof	1	2	7bfc375dee4b7a10	Highcroft CWA Hall
gl	1	30	9f86adc96cd8d612	Glenrose Park
gval	1	10	2c51c712b3204d2a	Springvale Hostel
hr	1	0	cbf29ce484222325	
iddl	1	30	f2b6f1941e24c425	Middle Track
ilso	1	30	6e182535696d1900	Wilson Street
ins	1	30	b5a3dd1b5ee3204b	Inside Plain
ju	1	30	d3c7816a6ab40284	Junction Cabin
kar	1	30	61b4e94ba2f7f0f0	Karls Hill
ki	1	30	87708d85562b84ab	Kingston
lair D	1	9	0753930d700d5782	Satans Lair
li	1	30	27a03ebd6c51d9c7	Lightwood Park
lin	1	30	4db640a8558466cc	Lindisfarne Point
merv	1	10	8861c3b25d397885	Merv Lewis Park
monw	1	18	d1011bff8774e64c	Commonwealth Law Courts
mr	1	6	b6c1c94ffaeda1e6	Mrs Teddys Lagoons
mu	1	30	4ad3cb3fd5c9f5c1	Murdochs Hill
na	1	30	a958f5c0d00e6c00	Natone Hill
nbark	1	3	196047e8086d4f10	Ironbark Drive
ndy C	1	30	bfc63c3f842cdf72	Grundys Creek
ne	1	30	8795e4b4ad316b9d	Neika
ng Cen	1	30	92b5141934ed4304	Rangeview Crescent
ntre	1	30	da7271176b283daa	Fern Tree Community Centre
ongana	1	13	0400c7f95dceee2f	Mongana Street
ook	1	30	e6c10ce15febd845	Wellington Falls Lookout Track
os Clo	1	30	fd594bd0d2914098	Moree Close
ove Ro	1	30	5d1e3894666550a6	Olinda Grove Sports Fields
pa	1	30	7a4f21faa302e2b1	Parliament Street Reserve
pe 	1	30	680737c5c22928b5	Peace Park
r Hill	1	30	275402655b23302d	Rosny Hill
r R	1	30	b7927999f0d45d3a	Richards Monument
ra	1	30	8fd9deca79da61b0	Radfords Monument
red	1	30	1c71e00bafe17480	Red Chapel Beach
reet	1	30	2e69eca419c6c8bb	Tagg Street
rh	1	30	b9359b5556cde1be	Rhyndaston
rl	1	0	cbf29ce484222325	
s Nest	1	30	70455e6292913699	Swallows Nest Lakes
s Rive	1	30	10e9b3f47fa7518b	Snug River
s Roa	1	30	2ffbb18f76df195d	Scotts Road
sl	1	30	6ff6c671d0c0cd02	Sleeping Beauty
ss Ba	1	0	cbf29ce484222325	
t Gel	1	26	1d8f39fd392f2c94	Gellibrands Marsh
tn	1	0	cbf29ce484222325	
tsid	1	15	3a00281c0b3d63d7	Mountside Saddle
tur	1	30	930016fc36d01b36	Turnip Fields
ur	1	13	b9d397bf4e7589f1	Urquhart Creek
urp	1	30	9012a5954b5d5524	Irish Murphy's
ve	1	30	0a346cc3afd9c87e	Vela Street Park
vn	1	0	cbf29ce484222325	
vt	1	0	cbf29ce484222325	
wage 	1	13	53f069af3c1023dd	Wagelhmina
yme	1	25	fa4741697de14d2e	Syme Street
zeley	1	1	7635f18c2f8cd1ba	Blazeley Road
"""
}
