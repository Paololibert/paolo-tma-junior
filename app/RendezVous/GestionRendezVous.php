<?php

declare(strict_types=1);

namespace App\RendezVous;

use DateInterval;
use DateTimeImmutable;
use DateTimeZone;

/**
 * Règles de gestion des rendez-vous au guichet.
 * Aucune base de données, aucun framework : l'heure courante et les rendez-vous existants sont passés en paramètres.
 */
final class GestionRendezVous
{
    public const CAPACITE_CRENEAU = 3;
    public const PAR_PAGE = 10;
    public const PREMIER_CRENEAU = 8 * 60;       // 08:00, en minutes depuis minuit
    public const DERNIER_CRENEAU = 15 * 60 + 30; // 15:30
    public const PAS_CRENEAU = 30;
    public const DELAI_ANNULATION_HEURES = 24;

    /** Toutes les heures sont celles du Bénin (GMT+1, pas d'heure d'été). */
    public static function fuseau(): DateTimeZone
    {
        return new DateTimeZone('+01:00');
    }

    /**
     * Contrôle une prise de rendez-vous et renvoie le rendez-vous à enregistrer (statut « confirmé »).
     *
     * @param  list<RendezVous>  $existants  rendez-vous déjà enregistrés (tous usagers)
     *
     * @throws RegleException
     */
    public function prendre(string $npi, string $service, string $dateHeure, DateTimeImmutable $maintenant, array $existants): RendezVous
    {
        if (preg_match('/\A[0-9]{10}\z/', $npi) !== 1) {
            throw RegleException::requeteInvalide(RegleException::NPI_INVALIDE);
        }

        $serviceEnum = Service::tryFrom($service);
        if ($serviceEnum === null) {
            throw RegleException::requeteInvalide(RegleException::SERVICE_INCONNU);
        }

        $debut = $this->lireDateHeure($dateHeure);

        if ($debut < $maintenant) {
            throw RegleException::conflit(RegleException::DATE_PASSEE);
        }

        if ((int) $debut->format('N') >= 6) {
            throw RegleException::conflit(RegleException::WEEK_END);
        }

        $minutes = (int) $debut->format('G') * 60 + (int) $debut->format('i');
        if ($minutes < self::PREMIER_CRENEAU || $minutes > self::DERNIER_CRENEAU || $minutes % self::PAS_CRENEAU !== 0) {
            throw RegleException::conflit(RegleException::HORS_GRILLE);
        }

        foreach ($existants as $rdv) {
            if ($rdv->npi === $npi && $rdv->estAVenir($maintenant)) {
                throw RegleException::conflit(RegleException::DEJA_A_VENIR);
            }
        }

        $occupees = 0;
        foreach ($existants as $rdv) {
            if ($rdv->occupeUnePlace() && $rdv->dateHeure == $debut) {
                $occupees++;
            }
        }
        if ($occupees >= self::CAPACITE_CRENEAU) {
            throw RegleException::conflit(RegleException::CRENEAU_PLEIN);
        }

        return new RendezVous(null, $npi, $serviceEnum, $debut, Statut::Confirme);
    }

    /**
     * Annule un rendez-vous confirmé, au plus tard 24 h avant l'heure prévue (24 h pile est accepté).
     *
     * @throws RegleException
     */
    public function annuler(RendezVous $rdv, DateTimeImmutable $maintenant): RendezVous
    {
        if ($rdv->statut !== Statut::Confirme) {
            throw RegleException::conflit(RegleException::NON_ANNULABLE);
        }

        $limite = $rdv->dateHeure->sub(new DateInterval('PT'.self::DELAI_ANNULATION_HEURES.'H'));
        if ($maintenant > $limite) {
            throw RegleException::conflit(RegleException::ANNULATION_TARDIVE);
        }

        return $rdv->avecStatut(Statut::Annule);
    }

    /**
     * Clôture un rendez-vous confirmé : « honore » ou « absent » uniquement. Les statuts finaux sont définitifs.
     *
     * @throws RegleException
     */
    public function changerStatut(RendezVous $rdv, string $statutDemande): RendezVous
    {
        $nouveau = Statut::tryFrom($statutDemande);
        if ($nouveau === null || ! in_array($nouveau, [Statut::Honore, Statut::Absent], true)) {
            throw RegleException::requeteInvalide(RegleException::STATUT_INVALIDE);
        }

        if ($rdv->statut->estDefinitif()) {
            throw RegleException::conflit(RegleException::DEJA_CLOTURE);
        }

        return $rdv->avecStatut($nouveau);
    }

    /**
     * Rendez-vous d'un usager : le prochain rendez-vous à venir en tête, puis du plus récent au plus ancien
     * (tri sur la vraie date, jamais sur le texte JJ/MM/AAAA), par pages de 10.
     *
     * @param  list<RendezVous>  $rendezVous  tous les rendez-vous connus
     * @return array{page: int, parPage: int, total: int, rendezVous: list<RendezVous>}
     */
    public function lister(array $rendezVous, string $npi, int $page, DateTimeImmutable $maintenant): array
    {
        $liste = array_values(array_filter($rendezVous, fn (RendezVous $r): bool => $r->npi === $npi));

        usort($liste, function (RendezVous $a, RendezVous $b) use ($maintenant): int {
            $aVenir = $a->estAVenir($maintenant);
            $bVenir = $b->estAVenir($maintenant);

            if ($aVenir !== $bVenir) {
                return $aVenir ? -1 : 1;           // à venir d'abord
            }

            if ($aVenir) {
                return [$a->dateHeure, $a->id] <=> [$b->dateHeure, $b->id]; // à venir : le plus proche en tête
            }

            return [$b->dateHeure, $b->id] <=> [$a->dateHeure, $a->id];     // passés : du plus récent au plus ancien
        });

        $page = max(1, $page);

        return [
            'page' => $page,
            'parPage' => self::PAR_PAGE,
            'total' => count($liste),
            'rendezVous' => array_slice($liste, ($page - 1) * self::PAR_PAGE, self::PAR_PAGE),
        ];
    }

    /** @throws RegleException */
    private function lireDateHeure(string $texte): DateTimeImmutable
    {
        $date = preg_match('/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/', $texte) === 1
            ? DateTimeImmutable::createFromFormat('!Y-m-d\TH:i', $texte, self::fuseau())
            : false;

        // Refuse aussi les dates « arrondies » par PHP (30 février, 24:00...).
        if ($date === false || $date->format('Y-m-d\TH:i') !== $texte) {
            throw RegleException::requeteInvalide(RegleException::DATE_ILLISIBLE);
        }

        return $date;
    }
}
