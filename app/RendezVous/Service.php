<?php

declare(strict_types=1);

namespace App\RendezVous;

enum Service: string
{
    case Passeport = 'PASSEPORT';
    case Cni = 'CNI';
    case Permis = 'PERMIS';
}
