<?php

declare(strict_types=1);

namespace Tests\Unit\RendezVous;

use App\RendezVous\GestionRendezVous;
use App\RendezVous\RegleException;
use App\RendezVous\RendezVous;
use App\RendezVous\Service;
use App\RendezVous\Statut;
use DateTimeImmutable;
use PHPUnit\Framework\TestCase;

/** Anomalies repérées dans l'export, sans ticket : grille horaire, longueur du NPI, doublon d'un même usager. */
class BonusTest extends TestCase
{
    private function heure(string $texte): DateTimeImmutable
    {
        return new DateTimeImmutable($texte, GestionRendezVous::fuseau());
    }

    private function assertRefus(int $code, string $message, callable $action): void
    {
        try {
            $action();
        } catch (RegleException $e) {
            $this->assertSame($code, $e->codeHttp);
            $this->assertSame($message, $e->getMessage());

            return;
        }

        $this->fail("Un refus était attendu : [$code] $message");
    }

    // Export : rendez-vous n° 490, 698, 842 à 16:00 / 16:30 alors que le dernier créneau est 15:30.
    public function test_le_dernier_creneau_est_15h30(): void
    {
        $gestion = new GestionRendezVous;
        $maintenant = $this->heure('2026-11-20 18:00');
        $refus = 'Créneau invalide : de 08:00 à 15:30, toutes les 30 minutes.';

        foreach (['2026-12-08T16:00', '2026-12-08T16:30', '2026-12-08T07:30', '2026-12-08T09:15'] as $date) {
            $this->assertRefus(409, $refus, fn () => $gestion->prendre('0387129160', 'PASSEPORT', $date, $maintenant, []));
        }

        foreach (['2026-12-08T08:00', '2026-12-08T15:30'] as $date) {
            $this->assertSame(Statut::Confirme, $gestion->prendre('0387129160', 'PASSEPORT', $date, $maintenant, [])->statut);
        }
    }

    // Export : NPI de 11 chiffres (n° 459) et de 12 chiffres (n° 642).
    public function test_un_npi_trop_long_est_refuse(): void
    {
        $gestion = new GestionRendezVous;

        foreach (['01234567890', '061425364711'] as $npi) {
            $this->assertRefus(400, 'Le NPI doit comporter exactement 10 chiffres.', fn () => $gestion->prendre(
                $npi, 'PERMIS', '2026-11-23T09:00', $this->heure('2026-11-20 18:00'), [],
            ));
        }
    }

    // Export : l'usager 0536455681 a deux rendez-vous le 01/09/2026 à 09:30 (n° 43 PERMIS et n° 99 PASSEPORT).
    public function test_un_meme_usager_ne_peut_pas_reserver_deux_fois_le_meme_creneau(): void
    {
        $gestion = new GestionRendezVous;
        $premier = new RendezVous(43, '0536455681', Service::Permis, $this->heure('2026-09-01 09:30'));

        $this->assertRefus(409, 'Vous avez déjà un rendez-vous à venir.', fn () => $gestion->prendre(
            '0536455681', 'PASSEPORT', '2026-09-01T09:30', $this->heure('2026-08-30 06:56'), [$premier],
        ));
    }
}
