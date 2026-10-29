#!/bin/bash
# À lancer depuis la racine du projet : bash install-rdv.sh
set -e
[ -f artisan ] || { echo "Lance ce script depuis ~/tma-rdv (le dossier qui contient artisan)."; exit 1; }
mkdir -p app/RendezVous tests/Unit/RendezVous database
[ -f base_rendez_vous.sql ] && mv base_rendez_vous.sql database/base_rendez_vous.sql
cat > app/RendezVous/Service.php <<'FIN_FICHIER'
<?php

declare(strict_types=1);

namespace App\RendezVous;

enum Service: string
{
    case Passeport = 'PASSEPORT';
    case Cni = 'CNI';
    case Permis = 'PERMIS';
}
FIN_FICHIER
cat > app/RendezVous/Statut.php <<'FIN_FICHIER'
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
FIN_FICHIER
cat > app/RendezVous/RegleException.php <<'FIN_FICHIER'
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
FIN_FICHIER
cat > app/RendezVous/RendezVous.php <<'FIN_FICHIER'
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
FIN_FICHIER
cat > app/RendezVous/GestionRendezVous.php <<'FIN_FICHIER'
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
FIN_FICHIER
cat > tests/Unit/RendezVous/TicketsTest.php <<'FIN_FICHIER'
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

class TicketsTest extends TestCase
{
    private GestionRendezVous $gestion;

    protected function setUp(): void
    {
        $this->gestion = new GestionRendezVous;
    }

    private function heure(string $texte): DateTimeImmutable
    {
        return new DateTimeImmutable($texte, GestionRendezVous::fuseau());
    }

    private function rdv(int $id, string $npi, string $date, Statut $statut = Statut::Confirme, Service $service = Service::Cni): RendezVous
    {
        return new RendezVous($id, $npi, $service, $this->heure($date), $statut);
    }

    /** Vérifie qu'une action est refusée avec le bon code HTTP et le message exact prévu. */
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

    // TMA-101 : anomalie — le samedi 14/11/2026 doit être refusé.
    public function test_tma_101_un_samedi_est_refuse(): void
    {
        $this->assertRefus(409, 'Le centre est fermé le week-end.', fn () => $this->gestion->prendre(
            '0614253647', 'PASSEPORT', '2026-11-14T10:00', $this->heure('2026-11-10 09:00'), [],
        ));

        // Le dimanche aussi, le vendredi est accepté.
        $this->assertRefus(409, 'Le centre est fermé le week-end.', fn () => $this->gestion->prendre(
            '0614253647', 'PASSEPORT', '2026-11-15T10:00', $this->heure('2026-11-10 09:00'), [],
        ));
        $rdv = $this->gestion->prendre('0614253647', 'PASSEPORT', '2026-11-13T10:00', $this->heure('2026-11-10 09:00'), []);
        $this->assertSame(Statut::Confirme, $rdv->statut);
    }

    // TMA-102 : anomalie — un 4e rendez-vous sur un créneau de 3 places doit être refusé.
    public function test_tma_102_creneau_plein_au_quatrieme(): void
    {
        $maintenant = $this->heure('2026-11-02 08:00');
        $existants = [
            $this->rdv(632, '0638958971', '2026-11-10 09:00'),
            $this->rdv(644, '0671968463', '2026-11-10 09:00'),
            $this->rdv(681, '0609394161', '2026-11-10 09:00'),
        ];

        $this->assertRefus(409, 'Ce créneau est complet.', fn () => $this->gestion->prendre(
            '0620214467', 'CNI', '2026-11-10T09:00', $maintenant, $existants,
        ));

        // Le 3e est encore accepté ; un rendez-vous annulé libère sa place.
        $this->gestion->prendre('0620214467', 'CNI', '2026-11-10T09:00', $maintenant, array_slice($existants, 0, 2));
        $existants[0] = $existants[0]->avecStatut(Statut::Annule);
        $rdv = $this->gestion->prendre('0620214467', 'CNI', '2026-11-10T09:00', $maintenant, $existants);
        $this->assertSame(Statut::Confirme, $rdv->statut);
    }

    // TMA-103 : anomalie — un NPI avec une lettre doit donner un refus 400, pas une erreur interne.
    public function test_tma_103_npi_avec_une_lettre_est_refuse_en_400(): void
    {
        $maintenant = $this->heure('2026-11-20 18:00');

        foreach (['06142A3647', '061425364', '06142536470', '', "0614253647\n"] as $npi) {
            $this->assertRefus(400, 'Le NPI doit comporter exactement 10 chiffres.', fn () => $this->gestion->prendre(
                $npi, 'CNI', '2026-11-23T09:00', $maintenant, [],
            ));
        }
    }

    // TMA-104 : anomalie — annuler 40 h avant doit être accepté ; le seuil est exactement 24 h.
    public function test_tma_104_annulation_a_40_heures_acceptee(): void
    {
        $rdv = $this->rdv(709, '0339205992', '2026-11-19 10:00', Statut::Confirme, Service::Permis);

        $annule = $this->gestion->annuler($rdv, $this->heure('2026-11-17 18:00'));
        $this->assertSame(Statut::Annule, $annule->statut);

        // 24 h pile : accepté ; 23 h 59 : refusé.
        $this->assertSame(Statut::Annule, $this->gestion->annuler($rdv, $this->heure('2026-11-18 10:00'))->statut);
        $this->assertRefus(409, 'Annulation impossible moins de 24 h avant le rendez-vous.', fn () => $this->gestion->annuler($rdv, $this->heure('2026-11-18 10:01')));
    }

    // TMA-105 : anomalie — un rendez-vous annulé ne peut plus être passé à « honoré ».
    public function test_tma_105_un_rendez_vous_annule_est_definitif(): void
    {
        $annule = $this->rdv(292, '0330677555', '2026-11-12 10:00', Statut::Annule, Service::Passeport);

        $this->assertRefus(409, 'Ce rendez-vous est déjà clôturé.', fn () => $this->gestion->changerStatut($annule, 'honore'));
        $this->assertRefus(409, 'Ce rendez-vous est déjà clôturé.', fn () => $this->gestion->changerStatut($this->rdv(1, '0330677555', '2026-11-12 10:00', Statut::Honore), 'absent'));
        $this->assertRefus(400, 'Statut invalide : honore ou absent.', fn () => $this->gestion->changerStatut($this->rdv(2, '0330677555', '2026-11-12 10:00'), 'annule'));

        $this->assertSame(Statut::Honore, $this->gestion->changerStatut($this->rdv(3, '0330677555', '2026-11-12 10:00'), 'honore')->statut);
    }

    // TMA-106 : anomalie — tri sur la vraie date, le prochain rendez-vous en tête, pages de 10.
    public function test_tma_106_prochain_rendez_vous_en_tete_et_tri_par_vraie_date(): void
    {
        $npi = '0203040506';
        $dates = [
            '2026-01-05 08:30', '2026-02-12 10:00', '2026-03-03 14:30', '2026-04-21 09:00', '2026-05-08 11:30',
            '2026-05-19 15:00', '2026-06-02 08:00', '2026-06-16 13:30', '2026-07-07 10:30', '2026-07-28 09:30',
            '2026-08-11 14:00', '2026-09-25 11:00',
        ];
        $rendezVous = [];
        foreach ($dates as $i => $date) {
            $rendezVous[] = $this->rdv($i + 1, $npi, $date, Statut::Honore);
        }
        $rendezVous[] = $this->rdv(826, $npi, '2026-12-02 08:30'); // le prochain, confirmé
        $rendezVous[] = $this->rdv(900, '0999999999', '2026-12-05 08:30'); // autre usager : ignoré

        $maintenant = $this->heure('2026-11-20 18:00');
        $page1 = $this->gestion->lister($rendezVous, $npi, 1, $maintenant);

        $this->assertSame(13, $page1['total']);
        $this->assertSame(10, $page1['parPage']);
        $this->assertCount(10, $page1['rendezVous']);
        $this->assertSame(
            ['02/12/2026 08:30', '25/09/2026 11:00', '11/08/2026 14:00', '28/07/2026 09:30'],
            array_map(fn (RendezVous $r) => $r->dateHeure->format('d/m/Y H:i'), array_slice($page1['rendezVous'], 0, 4)),
        );

        $page2 = $this->gestion->lister($rendezVous, $npi, 2, $maintenant);
        $this->assertCount(3, $page2['rendezVous']);
        $this->assertSame('05/01/2026 08:30', end($page2['rendezVous'])->dateHeure->format('d/m/Y H:i'));
    }

    // TMA-107 : CONFORME — un seul rendez-vous à venir par usager, tous services confondus.
    public function test_tma_107_le_refus_est_conforme_aux_regles(): void
    {
        $maintenant = $this->heure('2026-11-20 18:00');
        $existant = $this->rdv(800, '0102030405', '2026-11-26 10:00', Statut::Confirme, Service::Passeport);

        $this->assertRefus(409, 'Vous avez déjà un rendez-vous à venir.', fn () => $this->gestion->prendre(
            '0102030405', 'PERMIS', '2026-11-27T09:00', $maintenant, [$existant],
        ));

        // Une fois le rendez-vous annulé, ou passé, un nouveau est possible.
        $rdv = $this->gestion->prendre('0102030405', 'PERMIS', '2026-11-27T09:00', $maintenant, [$existant->avecStatut(Statut::Annule)]);
        $this->assertSame(Service::Permis, $rdv->service);
    }
}
FIN_FICHIER
touch requetes.sql
echo "Fichiers créés :"; ls app/RendezVous tests/Unit/RendezVous database requetes.sql
