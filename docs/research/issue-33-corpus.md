# Issue 33 real-meeting corpus research

Captured and checked against municipal websites on 2026-08-21. This note selects eight meetings and exactly three public agenda items from each meeting. It records the bytes that were checked, not only the mutable municipal URLs.

## Feasibility

The requested bounded corpus is feasible.

- The allowlist has eight real meetings across all four municipalities. Each municipality has two meetings.
- The 24-item sample below has exactly three items per meeting and covers public finance, housing, mobility, climate, schools, public works, culture, digital government, health care, and public safety.
- Ixelles 267, Uccle 2025-06-26, Forest 2025-04-22, and Forest 2026-03-24 have final public records at the official URLs below. This is more than the two meetings required for authoritative decisions.
- The City of Brussels pair contains a manually verified continuing dossier. Both records print the exact identifier `OPP/2026/185`. The later record also changes the stage from principle to attribution with extra expenditure. This link does not rely on title similarity.

## Explicit meeting allowlist

| Municipality | Municipal meeting identifier | Meeting date | Final record in the captured bundle |
| --- | --- | --- | --- |
| Ixelles | `267` | 2026-06-11 | Yes |
| Ixelles | `268` | 2026-07-02 | No |
| Uccle | `2025-06-26` | 2025-06-26 | Yes |
| Uccle | `2026-04-23` | 2026-04-23 | No, the official current-council table leaves "Registre des délibérations" empty |
| Forest | `2026-03-24` | 2026-03-24 | Yes |
| Forest | `2025-04-22` | 2025-04-22 | Yes |
| City of Brussels | `2026-06-29` | 2026-06-29 | No final minutes found on the cited 2026 document index |
| City of Brussels | `2026-06-08` | 2026-06-08 | No final minutes found on the cited 2026 document index |

This is the import boundary. The index pages were used only to verify municipal ownership and discover the listed locators. An implementation should reject any meeting identifier or source hash outside this table.

## Official discovery-page captures

The HTML pages can change, so their hashes are evidence of the version inspected. The PDF hashes in the next section are the immutable import keys.

| Role | Official URL | SHA-256 | Bytes |
| --- | --- | --- | ---: |
| Ixelles index | [https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr](https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr) | `22276d977a54ed7573c1f9ffc21806bb3774e2ee089471233f53d512e5aebf74` | 26,332 |
| Uccle current council | [https://www.uccle.be/fr/ma-commune/le-conseil-communal](https://www.uccle.be/fr/ma-commune/le-conseil-communal) | `c11ef10eaefd50d7a7ca0375f0ece6934e896ed918fbe24bbea803c0c68dff88` | 248,943 |
| Uccle archive | [https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal](https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal) | `c778ad7c6b60efbe52cb3a75f17b4f05753c5a21cf78411e95c2925aa4650a2e` | 974,153 |
| Forest index | [https://forest.brussels/fr/publications/conseil-communal-1](https://forest.brussels/fr/publications/conseil-communal-1) | `6a48cb123491d9a3004031cda6d1b14d59a29dd96c75ac52a300bda5ad47e1af` | 72,543 |
| City 2026 index | [https://www.brussels.be/agenda-reports-and-motions-city-council?field_date_document_value=2026](https://www.brussels.be/agenda-reports-and-motions-city-council?field_date_document_value=2026) | `40676f0cc03077a1bb72cfc399ee828c83c0b2f3ea47c0506c6ba570d0254037` | 55,833 |

## Exact official source versions

| Meeting | Source role | Official municipal URL | SHA-256 | Bytes | Pages |
| --- | --- | --- | --- | ---: | ---: |
| Ixelles 267 | complementary agenda | [https://www.ixelles.be/uploads/conseil/odj/267.pdf](https://www.ixelles.be/uploads/conseil/odj/267.pdf) | `750cffbd44374ef91499e6b8ba1f1d89c39ebc0e4d9a484c057ee9047b41a4bf` | 161,870 | 14 |
| Ixelles 267 | public minutes | [https://www.ixelles.be/uploads/conseil/pv/267.pdf](https://www.ixelles.be/uploads/conseil/pv/267.pdf) | `4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5` | 1,669,707 | 271 |
| Ixelles 268 | complementary agenda | [https://www.ixelles.be/uploads/conseil/odj/268.pdf](https://www.ixelles.be/uploads/conseil/odj/268.pdf) | `f412ee4ddc45b454691fff79b190e36de0ae60fe6b696ae7861c82557b38fd4b` | 216,552 | 25 |
| Ixelles 268 | public explanatory notes | [https://www.ixelles.be/uploads/conseil/projets/268.pdf](https://www.ixelles.be/uploads/conseil/projets/268.pdf) | `f3fddb8f231916b128b83002d2eeee82b591120b9aa556338a3992df95f9c1f4` | 2,680,949 | 483 |
| Uccle 2025-06-26 | base agenda | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJ_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJ_U1180_fr_nl.pdf) | `a7706d51b832142a956b5f37c6ce90bdbfd98fd0d7159be82bdec17b91755e8d` | 86,976 | 9 |
| Uccle 2025-06-26 | complementary agenda | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf) | `eb0fc81aef8cc9134b14a7dce60c9588394aa72c5a826e58fb9f9ece44a893e2` | 108,863 | 12 |
| Uccle 2025-06-26 | complementary explanatory notes | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-NEC-bis_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-NEC-bis_U1180_fr_nl.pdf) | `789afd485910ae2cb47ba1cd063a0ce36f7a1573dfb169ca7f3eae204d1ac932` | 983,680 | 149 |
| Uccle 2025-06-26 | public register | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf) | `3ea29d0bdf4e09f329cc73027fec8583f36b811f9999e671c37e86d7f71cc8f9` | 1,433,747 | 229 |
| Uccle 2026-04-23 | base agenda | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf) | `6f925fc048dd877a76bd164993964bc1e84365a65463e5976faa83ead9c83280` | 75,524 | 7 |
| Uccle 2026-04-23 | complementary agenda | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJC-U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJC-U1180_fr_nl.pdf) | `bcffa11940ed6177037318b646792d19ba2768cf4a89bd3f990b1999881caf2e` | 87,368 | 8 |
| Uccle 2026-04-23 | base explanatory notes | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-NE_U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-NE_U1180_fr_nl.pdf) | `100d4d423a3a94dc03ca87d0e10cf86d2d15d0259e9ed6ef2594f856d50540b7` | 1,562,011 | 66 |
| Uccle 2026-04-23 | complementary explanatory notes | [https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-NEC-U1180_fr_nl.pdf](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-NEC-U1180_fr_nl.pdf) | `940fb181094c797702adfcc4b2826d0ddf0de2ff3f6f2e4d4a5b35fdc2b3d2a5` | 1,131,539 | 68 |
| Forest 2026-03-24 | complementary agenda | [https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-03/CC-%2024032026%20-%20agenda%20compl%C3%A9mentaire.pdf](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-03/CC-%2024032026%20-%20agenda%20compl%C3%A9mentaire.pdf) | `e218e17e8c64b7c366d3512c0ec8389092827774b008dbe76ba04c2e97eaf4cc` | 74,281 | 5 |
| Forest 2026-03-24 | complementary explanatory notes | [https://forest.brussels/sites/default/files/publications/notes/2026-03/CC%20-%2024032026%20-%20Notes%20explicatives%20publiques%20compl%C3%A9mentaires.pdf](https://forest.brussels/sites/default/files/publications/notes/2026-03/CC%20-%2024032026%20-%20Notes%20explicatives%20publiques%20compl%C3%A9mentaires.pdf) | `9abc11c53c5e18813b1650015b371bdd691513440708fc838ea5904d1a258dc5` | 411,129 | 59 |
| Forest 2026-03-24 | public minutes | [https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf](https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf) | `6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26` | 568,679 | 92 |
| Forest 2025-04-22 | complementary agenda | [https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-04/CC%20-%2022042025%20-%20agenda%20compl.pdf](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-04/CC%20-%2022042025%20-%20agenda%20compl.pdf) | `806ea9d2411eac1caeb509e798a1556436611617192a6e4b565ebc4019b167e3` | 83,239 | 7 |
| Forest 2025-04-22 | complementary explanatory notes | [https://forest.brussels/sites/default/files/publications/notes/2025-04/22042025%20-%20Notes%20explicatives%20compl%C3%A9mentaires.pdf](https://forest.brussels/sites/default/files/publications/notes/2025-04/22042025%20-%20Notes%20explicatives%20compl%C3%A9mentaires.pdf) | `269f954075fb2f8cd9d796e5f1ad6e7cbf025bdd554062a01ef121e77cd6d489` | 479,672 | 67 |
| Forest 2025-04-22 | public minutes | [https://forest.brussels/sites/default/files/publications/registre/2025-04/PV%20%20conseil%20communal%20-%20gemeenteraad%2022042025.pdf](https://forest.brussels/sites/default/files/publications/registre/2025-04/PV%20%20conseil%20communal%20-%20gemeenteraad%2022042025.pdf) | `a40958fc8fb79c434f5fd6563d8a3ad244a0e3f01cb954433892c6104777dc81` | 1,265,953 | 190 |
| City of Brussels 2026-06-29 | agenda | [https://www.brussels.be/sites/default/files/OJ29062026.pdf](https://www.brussels.be/sites/default/files/OJ29062026.pdf) | `71925eae6e850e4f600858384bcaac082511fa53874a0125808d02317b57c3f8` | 483,244 | 13 |
| City of Brussels 2026-06-29 | supplement | [https://www.brussels.be/sites/default/files/OJsupp29062026.pdf](https://www.brussels.be/sites/default/files/OJsupp29062026.pdf) | `2feb53c3cb22ee958d267a7f03c6d830791f5ec8096584b743cb098bed1af66b` | 486,660 | 13 |
| City of Brussels 2026-06-08 | addendum | [https://www.brussels.be/sites/default/files/AddendumSP.pdf](https://www.brussels.be/sites/default/files/AddendumSP.pdf) | `5fa46feea773ed7825447b535f9de3f57a65a689c1666983907806bbe59595bb` | 427,947 | 1 |
| City of Brussels 2026-06-08 | agenda | [https://www.brussels.be/sites/default/files/OJSP08062026.pdf](https://www.brussels.be/sites/default/files/OJSP08062026.pdf) | `dd4c8a9d689ae87a1c169f5d56b522ce25cccc0facc9e9c65dbf2aac5ff3529e` | 485,929 | 14 |
| City of Brussels 2026-06-08 | supplement | [https://www.brussels.be/sites/default/files/OJsup08062026.pdf](https://www.brussels.be/sites/default/files/OJsup08062026.pdf) | `fcfa952cb807abbd963ac55e1bd183debb15ece80ecba408ad6f0fee706cb938` | 464,069 | 5 |

The Uccle archive labels a `CC-2025-05-22-NE...pdf` URL as the base explanatory notes for 2025-06-26. That date mismatch is real and should enter review. The selected Uccle items are present in the correctly dated complementary agenda and complementary notes recorded above. Do not silently relabel the May file as a June source.

## The 24 selected agenda items

The number shown here is the municipality's printed agenda number. For Ixelles, Uccle, and Forest, the citation includes the PDF page containing that number. City of Brussels also publishes one official HTML page per item, so those rows use that page as the stable anchor and give the internal workflow number printed in the agenda.

### Ixelles 267, 2026-06-11

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 4 | Rapport annuel 2025 sur la situation des affaires de la Commune et sur la gestion effectuée. | municipal governance | [source](https://www.ixelles.be/uploads/conseil/odj/267.pdf#page=2) |
| Item 14 | Occupation temporaire de la maison de repos "Les Heures Douces" par l'ASBL "On est là", partenaire de "Rockin'squat", en vue d'y héberger des femmes et enfants. Convention. Approbation. | emergency housing | [source](https://www.ixelles.be/uploads/conseil/odj/267.pdf#page=4) |
| Item 41 | Installation de quatre doubles bornes de recharge de véhicules électriques sur le patrimoine communal, marché SIBELGA `SIB20TW1601`, dépense de 336,663.24 EUR TVAC. | municipal fleet charging | [source](https://www.ixelles.be/uploads/conseil/odj/267.pdf#page=10) |

### Ixelles 268, 2026-07-02

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 1 | Interpellation citoyenne sur les mesures prises dans les écoles communales pour faire face aux canicules. | schools and heat | [source](https://www.ixelles.be/uploads/conseil/odj/268.pdf#page=1) |
| Item 10 | Cession par vente publique notariée du terrain communal cadastré `21446 D 60S & 64P`, à l'intersection de la rue des Mérisiers et de la rue du Relais. | municipal property | [source](https://www.ixelles.be/uploads/conseil/odj/268.pdf#page=3) |
| Item 13 | Subvention de 3,100 EUR au projet "Ixelles Speedcubing Contest", lauréat du budget participatif communal 2025-2026. | participatory budget | [source](https://www.ixelles.be/uploads/conseil/odj/268.pdf#page=3) |

### Uccle 2025-06-26

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 5 | Utilisation de caméras fixes temporaires contre les dépôts clandestins et les problèmes de propreté. | public cleanliness and cameras | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf#page=2) |
| Item 12 | Règlement-taxe sur les bornes de recharge pour véhicules électriques situées sur la voirie publique, exercices 2026-2031, adoption proposée. | tax and electric charging | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf#page=3) |
| Item 20 | Réaménagement de Bosveldweg, approbation de l'avant-projet, de la dépense, des documents du marché et de la procédure de passation. | street redesign | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf#page=4) |

### Uccle 2026-04-23

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 3 | Interpellation citoyenne sur la vente du parc du home Brugmann. | public land and care-home grounds | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf#page=1) |
| Item 18 | Règlement pour le déploiement d'un réseau de bornes de recharge pour véhicules électriques sur les voiries communales. | public electric charging | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf#page=4) |
| Item 25 | Budget 2026, approbation. | municipal finance | [source](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-ODJ_U1180_fr_nl.pdf#page=5) |

### Forest 2026-03-24

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 5 | Marché `SCA-2026-S-004` pour la réalisation, l'impression et la distribution du journal communal. | public communication procurement | [source](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-03/CC-%2024032026%20-%20agenda%20compl%C3%A9mentaire.pdf#page=2) |
| Item 11 | Marché `MP-2026-T-001` pour les travaux urgents sur les vitrages de l'église Saint-Denis. | heritage safety | [source](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-03/CC-%2024032026%20-%20agenda%20compl%C3%A9mentaire.pdf#page=3) |
| Item 16 | Achat de dispositifs de stationnement vélo sur le budget 2026 par la centrale d'achat de l'Agence du Stationnement. | bicycle parking | [source](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-03/CC-%2024032026%20-%20agenda%20compl%C3%A9mentaire.pdf#page=4) |

### Forest 2025-04-22

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 35 | Motion relative à la déclaration de Forest comme commune antifasciste et appartenant à la « coalition 8 mai ». | democratic values | [source](https://forest.brussels/sites/default/files/publications/registre/2025-07/PV%20%20conseil%20communal%20-%20gemeenteraad%2022042025.pdf#page=146) |
| Item 18 | Convention CECP pour le projet "Opération Recyclons" dans les écoles Kaléidoscope, de janvier 2024 à février 2027. | school waste reduction | [source](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-04/CC%20-%2022042025%20-%20agenda%20compl.pdf#page=3) |
| Item 31 | Tarif de rotation sur les bornes de recharge pour véhicules électriques, convention entre Sibelga et Forest. | charging-space turnover | [source](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-04/CC%20-%2022042025%20-%20agenda%20compl.pdf#page=6) |

### City of Brussels 2026-06-29

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 23, workflow `2713287` | Comptes de la Ville de l'exercice 2025, arrêt provisoire. | municipal finance | [official item page](https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20%28023%29); [agenda PDF](https://www.brussels.be/sites/default/files/OJ29062026.pdf#page=3) |
| Item 40, workflow `2721246` | Adhésion à eBox comme émetteur de communications officielles aux citoyens et entreprises. | digital government | [official item page](https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20%28040%29); [agenda PDF](https://www.brussels.be/sites/default/files/OJ29062026.pdf#page=5) |
| Supplement item 140, workflow `2721906` | Dossier `OPP/2026/185`, socles en béton pour modules Fritkot préfabriqués, attribution avec dépense supplémentaire. | public works procurement | [official item page](https://www.brussels.be/show_documents/29-06-2026s/29%2006%202026%20OJ%20point_punt%20%28140%29); [supplement PDF](https://www.brussels.be/sites/default/files/OJsupp29062026.pdf#page=7) |

### City of Brussels 2026-06-08

| Stable anchor | Selected agenda text | Topic | Evidence |
| --- | --- | --- | --- |
| Item 8, workflow `2717489` | Convention pour une avance de trésorerie de 4,000,000 EUR au CHU Brugmann. | public health finance | [official item page](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28008%29); [agenda PDF](https://www.brussels.be/sites/default/files/OJSP08062026.pdf#page=2) |
| Item 13, workflow `2716802` | Dossier `OPP/2026/185`, socles en béton pour modules Fritkot préfabriqués, principe. | public works procurement | [official item page](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28013%29); [agenda PDF](https://www.brussels.be/sites/default/files/OJSP08062026.pdf#page=3) |
| Item 36, workflow `2717652` | Subside de 90,000 EUR à Pro Vélo pour l'éducation au vélo dans les écoles de la Ville. | school mobility | [official item page](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28036%29); [agenda PDF](https://www.brussels.be/sites/default/files/OJSP08062026.pdf#page=6) |

### City item-page captures

These hashes pin the HTML anchors used above.

| Anchor | Official URL | SHA-256 | Bytes |
| --- | --- | --- | ---: |
| 2026-06-08 item 8 | [https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20(008)](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28008%29) | `779a7038de5347adcaae4a9e43218f64d976584facf5f62baf4a6f432ae11cc4` | 39,417 |
| 2026-06-08 item 13 | [https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20(013)](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28013%29) | `f99907ea6681df649c39bd2275bded6771c269e601f58fa95c2b57aac8b71fbb` | 39,037 |
| 2026-06-08 item 36 | [https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20(036)](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28036%29) | `ab5cb5af2c82c7abcce5b507c6e6acdadd0d277f25928a18c6c6867f67435f93` | 39,417 |
| 2026-06-29 item 23 | [https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20(023)](https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20%28023%29) | `771f29a86347f912412b51eda6246c42f55680d8377a723049cd37ab630041bc` | 41,173 |
| 2026-06-29 item 40 | [https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20(040)](https://www.brussels.be/show_documents/29-06-2026/29%2006%202026%20OJ%20point_punt%20%28040%29) | `33c095db34b405af6f931a25f641169b3b32097fa1216a856bb9800620cb7ea8` | 39,417 |
| 2026-06-29 item 140 | [https://www.brussels.be/show_documents/29-06-2026s/29%2006%202026%20OJ%20point_punt%20(140)](https://www.brussels.be/show_documents/29-06-2026s/29%2006%202026%20OJ%20point_punt%20%28140%29) | `df47e8faeb09cf83a298445919760ce3f02c731c20cdbec287917e4febd49beb` | 39,066 |

## Authoritative final decisions

These are outcomes from final registers or minutes. They are not summaries of proposal language.

1. Ixelles 267 item 4 has final decision reference `11.06.2026/A/0005`. The council approved the 2025 annual report by 37 positive votes out of 37. See the [official public minutes, page 19](https://www.ixelles.be/uploads/conseil/pv/267.pdf#page=19), pinned above as SHA-256 `4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5`.
2. Uccle 2025-06-26 item 5 approved the use of temporary fixed cameras, the processing arrangements, and the annexed location list by 36 positive votes out of 36. See the [official public register, page 10](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf#page=10), pinned above as SHA-256 `3ea29d0bdf4e09f329cc73027fec8583f36b811f9999e671c37e86d7f71cc8f9`.
3. Uccle 2025-06-26 item 12 adopted the public-road charging-station tax. The final text applies from 1 August 2025 through 31 December 2031, and the council approved it by 37 positive votes out of 37. The proposal agenda says "2026-2031", but the final register says "2025-2031". Preserve that distinction. See the [decision and operative text, pages 32-40](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf#page=32) and the [vote on page 40](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf#page=40).
4. Forest 2025-04-22 item 18 approved the CECP "Opération Recyclons" agreement for the Kaléidoscope nursery and primary schools by 35 positive votes out of 35. See the [official minutes, pages 98-99](https://forest.brussels/sites/default/files/publications/registre/2025-04/PV%20%20conseil%20communal%20-%20gemeenteraad%2022042025.pdf#page=98), pinned above as SHA-256 `a40958fc8fb79c434f5fd6563d8a3ad244a0e3f01cb954433892c6104777dc81`.
5. Forest 2026-03-24's bicycle-parking item designated parking.brussels for the purchase, recorded 16,423.25 EUR for three bicycle boxes, and recorded the matching regional subsidy. The council approved the deliberation by 32 positive votes out of 32. See the [official minutes, pages 57-58](https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf#page=57), pinned above as SHA-256 `6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26`.

## Manually verified continuing dossier

Use one dossier named `city-opp-2026-185-fritkot-socles` across the two City of Brussels meetings.

- On 2026-06-08, item 13 identifies `Dossier n° OPP/2026/185` and describes the concrete bases for prefabricated Fritkot modules at the `Principe` stage. The record also carries workflow number `2716802`. Evidence: [official item page](https://www.brussels.be/show_documents/08-06-2026/08%2006%202026%20OJ%20point_punt%20%28013%29) and the [agenda PDF](https://www.brussels.be/sites/default/files/OJSP08062026.pdf#page=3).
- On 2026-06-29, supplement item 140 repeats the exact identifier `Dossier n° OPP/2026/185` and the same object. It now says `Attribution avec dépense supplémentaire` and carries workflow number `2721906`. Evidence: [official item page](https://www.brussels.be/show_documents/29-06-2026s/29%2006%202026%20OJ%20point_punt%20%28140%29) and the [supplement PDF](https://www.brussels.be/sites/default/files/OJsupp29062026.pdf#page=7).

The shared municipal dossier identifier is the linkage evidence. The two workflow numbers differ because they identify separate council records. Do not use the workflow number as the dossier identity.

The Uccle charging material is related, but it is not the safest cross-meeting identity link. The 2026 deployment regulation expressly includes a municipal `règlement-taxe` in the applicable rules and requires operators to pay municipal taxes, fees, or charges. See the [2026 explanatory notes, pages 29-32](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-04-23-NE_U1180_fr_nl.pdf#page=29). However, that document does not print the 2025 meeting date or decision reference `26.06.2025/A/0013`. Keep it as a topic relationship, not a claim that both records share one formal dossier.

## Gaps and import cautions

- Source URLs are mutable. Import only the full SHA-256 values above, archive the bytes, and fail closed if a URL returns new bytes.
- No final record was found in the checked official listings for Ixelles 268, Uccle 2026-04-23, or the two City meetings. Their agenda text remains proposal-stage evidence.
- The City item pages for dossier `OPP/2026/185` expose the item anchor but no item attachment beyond the site's generic viewing instructions. The agenda and supplement PDFs still carry the exact item number, workflow number, dossier identifier, stage, and object.
- The Uccle 2025-06-26 base explanatory-notes link has a May filename. Route it to review rather than guessing intent.
- This research pins sources and French agenda text. It does not create FR/NL/EN generated variants, translation provenance, authenticated batch records, cost records, or publication measurements. Those remain implementation work for issue 33.

## Implemented sealed bundle

Issue 33 selects nine of the official versions above. Their exact 8,172,482 bytes are stored under `priv/corpus/issue-33/sources/` and described by `priv/corpus/issue-33/manifest.json`. The manifest digest at implementation time is `4b5d56695b76ee485ca06344c219f6c4b55d5bd91e96138bd7a230f80390129e`. The Uccle 2026-04-23 heading marker uses Poppler's normalized extraction `CONSEIL COMMUNAL DU 23 AVRIL 2026`; the pinned municipal bytes are unchanged.

The importer reads the release-owned files, verifies their byte counts and SHA-256 values, and records each original HTTPS locator, exact discovery parent, and captured-at timestamp from the research session as provenance. It makes no network requests. New bytes from a later municipal publication require an explicit manifest and bundle revision; they cannot silently replace this corpus.

The recorded FR/NL/EN coverage was drafted with `openai-codex/gpt-5.6-sol`, then checked against the pinned source wording and reviewed as part of the sealed corpus. Its immutable run metadata carries both the original AI/machine-translation labels and the later human-review label. It is keyed to the complete normalized publication input. A changed item set, source wording, claim, state, disposition, or source hash fails closed. The continuing City dossier is created only after all eight meetings normalize to the exact 24-item contract. Its two links are recorded as reviewer-confirmed actions with `OPP/2026/185` as the authoritative match feature.
