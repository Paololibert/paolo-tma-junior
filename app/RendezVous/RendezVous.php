<?php

declare(strict_types=1);

namespace App\RendezVous;

use DateTimeImmutable;

/** Un rendez-vous (données seulement, indépendant de la base). Immuable : chaque changement renvoie une copie. */
final class RendezVous
{
    public function __construct(
        public readonly ?int $id,
        public readonly string $npi,
        public readonly Service $service,
        public readonly DateTimeImmutable $dateHeure,
        public readonly Statut $statut = Statut::Confirme,
    ) {}

    public function avecStatut(Statut $statut): self
    {
        return new self($this->id, $this->npi, $this->service, $this->dateHeure, $statut);
    }

    /** Occupe une place dans son créneau tant qu'il n'est pas annulé. */
    public function occupeUnePlace(): bool
    {
        return $this->statut !== Statut::Annule;
    }

    /** Rendez-vous à venir : non annulé et pas encore passé. */
    public function estAVenir(DateTimeImmutable $maintenant): bool
    {
        return $this->occupeUnePlace() && $this->dateHeure >= $maintenant;
    }
}
