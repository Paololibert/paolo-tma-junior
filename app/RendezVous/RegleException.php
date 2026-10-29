<?php

declare(strict_types=1);

namespace App\RendezVous;

use RuntimeException;

/** Refus d'une règle de gestion : code HTTP + message prévu par le sujet (jamais une erreur interne). */
final class RegleException extends RuntimeException
{
    public const NPI_INVALIDE = 'Le NPI doit comporter exactement 10 chiffres.';
    public const SERVICE_INCONNU = 'Service inconnu : choisissez PASSEPORT, CNI ou PERMIS.';
    public const DATE_ILLISIBLE = 'Date et heure invalides (format attendu : AAAA-MM-JJTHH:MM).';
    public const DATE_PASSEE = 'Impossible de prendre un rendez-vous dans le passé.';
    public const WEEK_END = 'Le centre est fermé le week-end.';
    public const HORS_GRILLE = 'Créneau invalide : de 08:00 à 15:30, toutes les 30 minutes.';
    public const DEJA_A_VENIR = 'Vous avez déjà un rendez-vous à venir.';
    public const CRENEAU_PLEIN = 'Ce créneau est complet.';
    public const NON_ANNULABLE = 'Ce rendez-vous ne peut plus être annulé.';
    public const ANNULATION_TARDIVE = 'Annulation impossible moins de 24 h avant le rendez-vous.';
    public const STATUT_INVALIDE = 'Statut invalide : honore ou absent.';
    public const DEJA_CLOTURE = 'Ce rendez-vous est déjà clôturé.';

    public function __construct(public readonly int $codeHttp, string $message)
    {
        parent::__construct($message);
    }

    public static function requeteInvalide(string $message): self
    {
        return new self(400, $message);
    }

    public static function conflit(string $message): self
    {
        return new self(409, $message);
    }
}
