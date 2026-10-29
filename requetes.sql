-- requetes.sql : mesure d'impact sur l'export du vendredi 20/11/2026 à 18h00 (heure du Bénin).
-- Écrit et exécuté sur SQLite : sqlite3 rdv.db < requetes.sql
-- Les passages propres à un moteur (jour de la semaine) sont donnés en commentaire pour MySQL et PostgreSQL.

-- 1) Rendez-vous confirmés à venir pris un samedi ou un dimanche (usagers à prévenir) — ticket TMA-101
--    « À venir » = après l'heure de l'export.
SELECT id, npi, service, date_heure, cree_le
FROM rendez_vous
WHERE statut = 'confirme'
  AND date_heure > '2026-11-20 18:00:00'
  AND strftime('%w', date_heure) IN ('0', '6')      -- SQLite : 0 = dimanche, 6 = samedi
  -- MySQL      : AND DAYOFWEEK(date_heure) IN (1, 7)
  -- PostgreSQL : AND EXTRACT(DOW FROM date_heure) IN (0, 6)
ORDER BY date_heure, id;

-- 2) Créneaux qui comptent plus de 3 rendez-vous non annulés — ticket TMA-102
SELECT date_heure,
       COUNT(*) AS nb_rendez_vous,
       GROUP_CONCAT(id) AS ids      -- PostgreSQL : STRING_AGG(id::text, ',')
FROM rendez_vous
WHERE statut <> 'annule'
GROUP BY date_heure
HAVING COUNT(*) > 3
ORDER BY date_heure;

-- 3) Rendez-vous passés du statut « annulé » à un autre statut — ticket TMA-105
SELECT r.id AS rendez_vous_id, r.npi, r.date_heure,
       h.ancien_statut, h.nouveau_statut, h.modifie_le, h.modifie_par
FROM historique_statuts h
JOIN rendez_vous r ON r.id = h.rendez_vous_id
WHERE h.ancien_statut = 'annule'
  AND h.nouveau_statut <> 'annule'
ORDER BY h.modifie_le;

-- Bonus : NPI qui ne comptent pas exactement 10 chiffres
SELECT id, npi, LENGTH(npi) AS longueur
FROM rendez_vous
WHERE LENGTH(npi) <> 10 OR npi GLOB '*[^0-9]*';   -- MySQL : npi NOT REGEXP '^[0-9]{10}$'

-- Bonus : rendez-vous hors grille (dernier créneau autorisé : 15:30)
SELECT id, date_heure, statut
FROM rendez_vous
WHERE strftime('%H:%M', date_heure) < '08:00'
   OR strftime('%H:%M', date_heure) > '15:30'
   OR strftime('%M', date_heure) NOT IN ('00', '30')   -- MySQL : DATE_FORMAT(date_heure, '%H:%i') / '%i'
ORDER BY date_heure;

-- Bonus : un même usager avec plusieurs rendez-vous non annulés sur le même créneau
SELECT npi, date_heure, COUNT(*) AS nb, GROUP_CONCAT(id) AS ids
FROM rendez_vous
WHERE statut <> 'annule'
GROUP BY npi, date_heure
HAVING COUNT(*) > 1;
