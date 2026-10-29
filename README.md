# Étude de cas TMA — Prise de rendez-vous au guichet

Module de règles de gestion en PHP pur (sans base de données ni framework), tests automatisés et requêtes d'impact sur l'export de la base.

## Lancer les tests

```bash
composer install
cp .env.example .env && php artisan key:generate
php artisan test                      # ou : vendor/bin/phpunit
php artisan test --filter=TicketsTest # les 7 tickets seulement
```

Laravel ne sert que de support pour PHPUnit : le module `app/RendezVous/` n'utilise ni Eloquent ni aucune classe du framework. Les tests (10 pour l'étude de cas, plus 2 exemples fournis par Laravel) ne touchent pas la base.

## Contenu du dépôt

```
app/RendezVous/
├── GestionRendezVous.php   règles : prendre(), annuler(), changerStatut(), lister()
├── RendezVous.php          un rendez-vous (données seulement, immuable)
├── Service.php             PASSEPORT | CNI | PERMIS
├── Statut.php              confirme | honore | absent | annule
└── RegleException.php      code HTTP + message exact prévu par le sujet
tests/Unit/RendezVous/
├── TicketsTest.php         un test par ticket (TMA-101 à TMA-107)
└── BonusTest.php           anomalies repérées dans l'export (sans ticket)
database/base_rendez_vous.sql   export fourni
requetes.sql                    requêtes d'impact
```

Le module reçoit **l'heure courante** et **les rendez-vous existants** en paramètres, ce qui le rend testable. Toutes les heures sont celles du Bénin (UTC+01:00).

### Choix d'interprétation
- **Rendez-vous « à venir »** : non annulé et pas encore passé.
- **Créneau complet** : 3 rendez-vous non annulés ; un rendez-vous annulé libère sa place.
- **Annulation « jusqu'à 24 h avant »** : inclusif. À 24 h pile elle est acceptée, une minute plus tard elle est refusée.
- **Ordre des contrôles d'une prise** : NPI, service, format de la date, date passée, week-end, grille horaire, rendez-vous déjà à venir, créneau plein (l'ordre du tableau du sujet).
- **Liste d'un usager** : le prochain rendez-vous à venir en tête, puis les autres du plus récent au plus ancien, triés sur la vraie date, par pages de 10.

## Tickets

| Ticket | Qualification |
|---|---|
| TMA-101 | Anomalie |
| TMA-102 | Anomalie |
| TMA-103 | Anomalie |
| TMA-104 | Anomalie |
| TMA-105 | Anomalie |
| TMA-106 | Anomalie |
| TMA-107 | **Conforme** |

### TMA-101 — Rendez-vous accepté un samedi
- **Qualification** : anomalie. Règle : « Le centre reçoit du lundi au vendredi ». Réponse attendue : 409 « Le centre est fermé le week-end. »
- **Cause probable** : le contrôle du jour de la semaine est absent. Le 14/11/2026 est un samedi et la requête passe en 201. L'export contient 8 rendez-vous confirmés un samedi ou un dimanche.
- **Correction** : `GestionRendezVous::prendre()` refuse si le jour ISO est ≥ 6.
- **Test** : `test_tma_101_un_samedi_est_refuse` (rejoue le 14/11/2026 ; vérifie aussi le dimanche et le vendredi).

### TMA-102 — Quatre usagers sur un créneau de trois places
- **Qualification** : anomalie. Règle : « Un créneau accueille au plus 3 usagers ».
- **Cause probable** : erreur de borne (comparaison `> 3` au lieu de `>= 3` sur le nombre de rendez-vous existants). Une concurrence entre deux réservations est écartée : le n° 697 a été créé le 04/11 à 23:43, plus de deux jours après le n° 681 (02/11 à 18:47).
- **Correction** : refus « Ce créneau est complet. » dès que 3 rendez-vous non annulés occupent le créneau.
- **Test** : `test_tma_102_creneau_plein_au_quatrieme` (3 existants → le 4ᵉ est refusé ; le 3ᵉ est accepté ; un annulé libère sa place).

### TMA-103 — « Erreur interne du serveur » avec une lettre dans le NPI
- **Qualification** : anomalie. Règle : le NPI est « composé d'exactement 10 chiffres » et une saisie invalide est refusée avec un message, « jamais par une erreur interne ». Réponse attendue : 400 « Le NPI doit comporter exactement 10 chiffres. »
- **Cause probable** : le NPI est converti en nombre (ou utilisé) avant d'être validé : `06142A3647` provoque une exception non gérée, donc un 500.
- **Correction** : validation stricte `^[0-9]{10}$` avant toute autre opération, avant même la lecture du service.
- **Test** : `test_tma_103_npi_avec_une_lettre_est_refuse_en_400` (lettre, 9 chiffres, 11 chiffres, vide, retour à la ligne final).

### TMA-104 — Annulation refusée 40 h avant le rendez-vous
- **Qualification** : anomalie. Le 17/11 à 18:00, le rendez-vous du 19/11 à 10:00 est à 40 h. Règle : « jusqu'à 24 heures avant l'heure prévue ». Le refus est donc à tort.
- **Cause probable** : l'écart n'est pas calculé sur des dates complètes. Par exemple, il est calculé sur l'heure du jour seule (10 h − 18 h = −8 h, jugé « moins de 24 h »), ou le jour est ignoré.
- **Correction** : on compare `maintenant` à `date_heure − 24 h` sur des dates complètes. Accepté si `maintenant ≤ date_heure − 24 h`.
- **Test** : `test_tma_104_annulation_a_40_heures_acceptee` (le cas du ticket, 24 h pile accepté, 23 h 59 refusé).

### TMA-105 — Un rendez-vous annulé passé à « honoré »
- **Qualification** : anomalie. Règle : « Ces trois statuts sont définitifs ». Réponse attendue : 409 « Ce rendez-vous est déjà clôturé. »
- **Cause probable** : seule la valeur demandée est contrôlée, pas le statut actuel. L'historique contient 4 passages de « annulé » à « honoré » ou « absent » (voir les requêtes).
- **Correction** : `changerStatut()` accepte uniquement `honore` ou `absent` (sinon 400 « Statut invalide : honore ou absent. »), et seulement depuis `confirme` (sinon 409).
- **Test** : `test_tma_105_un_rendez_vous_annule_est_definitif`.

### TMA-106 — Le prochain rendez-vous n'est pas en tête
- **Qualification** : anomalie. Règle : « du plus récent au plus ancien, le prochain rendez-vous en tête, par pages de 10 ».
- **Cause probable** : tri sur le texte `JJ/MM/AAAA`. Les dates de la trace sont en ordre décroissant de **jour du mois** (28, 25, 21, 19, 16, 12, 11, 08, 07), ce qui est un tri alphabétique sur la chaîne formatée. Le 02/12 se retrouve donc loin dans la liste, hors de la première page.
- **Correction** : tri sur la vraie date. Les rendez-vous à venir passent d'abord (le plus proche en tête), puis les passés du plus récent au plus ancien, avec 10 résultats par page.
- **Test** : `test_tma_106_prochain_rendez_vous_en_tete_et_tri_par_vraie_date` (13 rendez-vous de l'usager 0203040506 : le 02/12/2026 est premier, 10 sur la page 1, 3 sur la page 2).

### TMA-107 — Un deuxième rendez-vous refusé
- **Qualification** : **comportement conforme**. Règle : « Un usager ne peut avoir qu'un seul rendez-vous à venir, tous services confondus ». L'usager 0102030405 a déjà le rendez-vous n° 800 (PASSEPORT, 26/11/2026 à 10:00, confirmé) : le refus 409 est correct.
- **Correction** : aucune.
- **Test** : `test_tma_107_le_refus_est_conforme_aux_regles` (le refus reste ; un nouveau rendez-vous est possible une fois l'ancien annulé).

## Impact sur les données (`requetes.sql`)

Export du vendredi 20/11/2026 à 18:00 chargé dans SQLite : 889 rendez-vous.

```bash
sqlite3 rdv.db < database/base_rendez_vous.sql
sqlite3 -header rdv.db < requetes.sql
```
Les variantes MySQL et PostgreSQL sont indiquées en commentaire dans `requetes.sql`.

**1. Rendez-vous confirmés à venir pris un week-end (usagers à prévenir) : 5**

| id | NPI | service | date |
|---|---|---|---|
| 680 | 0669147625 | PASSEPORT | 21/11/2026 08:30 |
| 730 | 0679617916 | CNI | 28/11/2026 09:00 |
| 834 | 0610588823 | CNI | 05/12/2026 10:00 |
| 857 | 0671987446 | PERMIS | 05/12/2026 10:00 |
| 874 | 0648953073 | PASSEPORT | 12/12/2026 11:00 |

**2. Créneaux avec plus de 3 rendez-vous non annulés : 3**

| créneau | nombre | rendez-vous |
|---|---|---|
| 22/10/2026 10:30 | 4 | 502, 511, 517, 519 |
| 10/11/2026 09:00 | 4 | 632, 644, 681, 697 |
| 24/11/2026 14:00 | 4 | 728, 750, 763, 783 (à venir : à traiter) |

**3. Rendez-vous passés d'« annulé » à un autre statut : 4**

| rendez-vous | date | changement | par |
|---|---|---|---|
| 208 | 07/10/2026 10:00 | annulé → honoré | AG-01 |
| 231 | 15/10/2026 10:00 | annulé → honoré | AG-02 |
| 262 | 29/10/2026 10:00 | annulé → absent | AG-03 |
| 292 | 12/11/2026 10:00 | annulé → honoré | AG-04 |

## Bonus — anomalies non signalées

1. **Dernier créneau mal contrôlé** : les rendez-vous n° 490 (27/10, 16:00), n° 698 (13/11, 16:30) et n° 842 (08/12, 16:00) sont hors grille. Le dernier créneau est 15:30. La borne haute est probablement trop large. Le n° 842 est encore à venir.
2. **NPI trop longs** : n° 459 (`01234567890`, 11 chiffres) et n° 642 (`061425364711`, 12 chiffres). Le contrôle accepte « au moins 10 chiffres » ou ne vérifie pas la longueur maximale.
3. **Doublon d'un usager** : l'usager 0536455681 a deux rendez-vous le 01/09/2026 à 09:30 (n° 43 PERMIS, pris le 24/08, et n° 99 PASSEPORT, pris le 30/08). La règle « un seul rendez-vous à venir » n'a pas été appliquée lors de la 2ᵉ réservation.
4. **Rendez-vous passés jamais clôturés** : les n° 475, 742 et 715 sont restés « confirmé » alors que leur date est passée. Ce sont des rendez-vous du samedi (conséquence du ticket TMA-101) : aucun agent ne pouvait les clôturer.

Les règles correspondantes (points 1 à 3) sont corrigées dans `GestionRendezVous` et couvertes par `BonusTest`. Le point 4 relève d'un traitement de données : clôturer ou annuler ces rendez-vous et prévenir les usagers.
