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

/** Cas limites des règles de gestion (grille, formats, ordre des contrôles, annulation, pagination). */
class CasLimitesTest extends TestCase
{
    private GestionRendezVous $gestion;

    private DateTimeImmutable $maintenant;

    protected function setUp(): void
    {
        $this->gestion = new GestionRendezVous;
        $this->maintenant = $this->heure('2026-11-20 18:00'); // vendredi, heure de l'export
    }

    private function heure(string $texte): DateTimeImmutable
    {
        return new DateTimeImmutable($texte, GestionRendezVous::fuseau());
    }

    private function rdv(int $id, string $npi, string $date, Statut $statut = Statut::Confirme): RendezVous
    {
        return new RendezVous($id, $npi, Service::Cni, $this->heure($date), $statut);
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

    private function prendre(string $date, array $existants = [], string $npi = '0614253647', string $service = 'CNI'): RendezVous
    {
        return $this->gestion->prendre($npi, $service, $date, $this->maintenant, $existants);
    }

    public function test_premier_et_dernier_creneau_sont_acceptes(): void
    {
        $this->assertSame(Statut::Confirme, $this->prendre('2026-11-23T08:00')->statut);
        $this->assertSame(Statut::Confirme, $this->prendre('2026-11-23T15:30')->statut);
    }

    public function test_heures_hors_grille_sont_refusees(): void
    {
        $message = 'Créneau invalide : de 08:00 à 15:30, toutes les 30 minutes.';

        foreach (['07:30', '07:59', '09:15', '15:45', '16:00', '16:30', '18:00'] as $heure) {
            $this->assertRefus(409, $message, fn () => $this->prendre("2026-11-23T$heure"));
        }
    }

    public function test_date_passee_est_refusee(): void
    {
        $this->assertRefus(409, 'Impossible de prendre un rendez-vous dans le passé.', fn () => $this->prendre('2026-11-19T10:00'));
    }

    public function test_formats_de_date_illisibles_sont_refuses_en_400(): void
    {
        $message = 'Date et heure invalides (format attendu : AAAA-MM-JJTHH:MM).';

        foreach (['2026-11-23 09:00', '23/11/2026 09:00', '2026-02-30T09:00', '2026-11-23T24:00', 'demain', ''] as $date) {
            $this->assertRefus(400, $message, fn () => $this->prendre($date));
        }
    }

    public function test_service_inconnu_est_refuse_en_400(): void
    {
        foreach (['PASSPORT', 'cni', ''] as $service) {
            $this->assertRefus(400, 'Service inconnu : choisissez PASSEPORT, CNI ou PERMIS.', fn () => $this->prendre('2026-11-23T09:00', [], '0614253647', $service));
        }
    }

    public function test_ordre_des_controles(): void
    {
        // NPI avant service ; service avant date ; week-end avant grille ; grille avant créneau plein.
        $this->assertRefus(400, 'Le NPI doit comporter exactement 10 chiffres.', fn () => $this->prendre('demain', [], 'abc', 'XXX'));
        $this->assertRefus(400, 'Service inconnu : choisissez PASSEPORT, CNI ou PERMIS.', fn () => $this->prendre('demain', [], '0614253647', 'XXX'));
        $this->assertRefus(409, 'Le centre est fermé le week-end.', fn () => $this->prendre('2026-11-21T16:00'));
    }

    public function test_un_ancien_rendez_vous_honore_ou_annule_ne_bloque_pas(): void
    {
        $honore = $this->rdv(9, '0614253647', '2026-11-10 09:00', Statut::Honore);
        $annule = $this->rdv(10, '0614253647', '2026-11-25 09:00', Statut::Annule);

        $this->assertSame(Statut::Confirme, $this->prendre('2026-11-23T09:00', [$honore, $annule])->statut);
    }

    public function test_deux_usagers_differents_sur_le_meme_creneau(): void
    {
        $autre = $this->rdv(1, '0222222222', '2026-11-23 09:00');

        $this->assertSame(Statut::Confirme, $this->prendre('2026-11-23T09:00', [$autre])->statut);
    }

    public function test_annulation_exactement_a_24_heures(): void
    {
        $rdv = $this->rdv(1, '0614253647', '2026-11-23 09:00');

        $this->assertSame(Statut::Annule, $this->gestion->annuler($rdv, $this->heure('2026-11-22 09:00'))->statut);
        $this->assertRefus(409, 'Annulation impossible moins de 24 h avant le rendez-vous.', fn () => $this->gestion->annuler($rdv, $this->heure('2026-11-22 09:01')));
    }

    public function test_annulation_impossible_si_le_rendez_vous_n_est_pas_confirme(): void
    {
        foreach ([Statut::Annule, Statut::Honore, Statut::Absent] as $statut) {
            $this->assertRefus(409, 'Ce rendez-vous ne peut plus être annulé.', fn () => $this->gestion->annuler(
                $this->rdv(1, '0614253647', '2026-12-10 09:00', $statut), $this->heure('2026-11-01 09:00'),
            ));
        }
    }

    public function test_changement_de_statut_valeurs_interdites(): void
    {
        $rdv = $this->rdv(1, '0614253647', '2026-11-23 09:00');

        foreach (['confirme', 'annule', 'HONORE', ''] as $statut) {
            $this->assertRefus(400, 'Statut invalide : honore ou absent.', fn () => $this->gestion->changerStatut($rdv, $statut));
        }

        $this->assertSame(Statut::Absent, $this->gestion->changerStatut($rdv, 'absent')->statut);
    }

    public function test_un_statut_definitif_ne_change_plus(): void
    {
        foreach ([Statut::Honore, Statut::Absent, Statut::Annule] as $statut) {
            $this->assertRefus(409, 'Ce rendez-vous est déjà clôturé.', fn () => $this->gestion->changerStatut(
                $this->rdv(1, '0614253647', '2026-11-23 09:00', $statut), 'honore',
            ));
        }
    }

    public function test_pagination_pages_vides_et_page_zero(): void
    {
        $liste = [];
        for ($i = 1; $i <= 25; $i++) {
            $liste[] = $this->rdv($i, '0111111111', '2026-01-01 08:00', Statut::Honore);
        }

        $this->assertSame(10, count($this->gestion->lister($liste, '0111111111', 0, $this->maintenant)['rendezVous']));
        $this->assertSame(1, $this->gestion->lister($liste, '0111111111', 0, $this->maintenant)['page']);
        $this->assertSame(5, count($this->gestion->lister($liste, '0111111111', 3, $this->maintenant)['rendezVous']));
        $this->assertSame(0, count($this->gestion->lister($liste, '0111111111', 4, $this->maintenant)['rendezVous']));
        $this->assertSame(0, $this->gestion->lister($liste, '0999999999', 1, $this->maintenant)['total']);
    }

    public function test_un_rendez_vous_a_venir_annule_ne_passe_pas_avant_le_prochain(): void
    {
        $liste = [
            $this->rdv(1, '0111111111', '2026-12-20 09:00', Statut::Annule), // plus tard, mais annulé
            $this->rdv(2, '0111111111', '2026-12-02 09:00'),                 // le vrai prochain
            $this->rdv(3, '0111111111', '2026-11-10 09:00', Statut::Honore),
        ];

        $ids = array_map(fn (RendezVous $r) => $r->id, $this->gestion->lister($liste, '0111111111', 1, $this->maintenant)['rendezVous']);

        $this->assertSame([2, 1, 3], $ids);
    }
}
