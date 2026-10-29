<?php

declare(strict_types=1);

namespace App\RendezVous;

enum Statut: string
{
    case Confirme = 'confirme';
    case Honore = 'honore';
    case Absent = 'absent';
    case Annule = 'annule';

    /** Honoré, absent et annulé sont définitifs : seul « confirmé » peut encore changer. */
    public function estDefinitif(): bool
    {
        return $this !== self::Confirme;
    }
}
