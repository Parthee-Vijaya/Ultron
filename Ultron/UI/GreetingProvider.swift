import Foundation

/// Rotating greeting shown in the chat empty-state. v1.4 Fase 2c: instead of
/// the static "Hvad har du på hjerte?" every new chat picks a random line
/// from a curated library — film quotes, one-liners, Ultron-butler banter,
/// Bond/Stark/Hobbit references — so each session feels slightly different.
///
/// 200 lines, Danish-weighted, keeps the `{name}` placeholder substitution
/// minimal. Caller passes a nickname (default "P"); `{name}` tokens in the
/// line are replaced with it at render time.
enum GreetingProvider {
    /// Returns a random subline paired with a rendered "Hej {name}" preheader.
    /// Same call on the same second yields the same line (the calendar second
    /// is used as a weak seed) so a rapid re-render doesn't flash two
    /// different greetings — but a genuinely fresh empty-state picks a new one.
    static func random(name: String, seed: Int? = nil) -> (hello: String, line: String) {
        let effectiveSeed = seed ?? Int(Date().timeIntervalSince1970)
        let pool = Self.all
        let index = abs(effectiveSeed) % pool.count
        let raw = pool[index]
        let line = raw.replacingOccurrences(of: "{name}", with: name)
        return (hello: "Hej \(name)", line: line)
    }

    /// 200 rotating sub-greetings. Mix of:
    ///  • Danish butler / boss style ("Hvad skal vi lave, boss?")
    ///  • Ultron-canonical Tony Stark banter
    ///  • Film quotes gently re-purposed
    ///  • Action-movie one-liners
    ///  • Nerdy references (Bond, Star Wars, Matrix, Hobbit, LOTR, Die Hard, Godfather…)
    ///  • Quiet competent-butler lines
    /// `{name}` tokens are substituted with the nickname.
    static let all: [String] = [
        // 1–25 — Ultron / butler / Tony Stark
        "Hvad skal vi lave, boss?",
        "Klar, {name}. Hvad har du brug for?",
        "Giv mig et projekt.",
        "Er vi klar?",
        "Systemerne kører. Bare sig til.",
        "Hvad er planen i dag?",
        "Til tjeneste, {name}.",
        "Hvor starter vi?",
        "Hvad skal vi knække først?",
        "Hvad har du på hjerte?",
        "Operationen er din, jeg er kun hænderne.",
        "Jeg er her. Hvad kalder du mig til?",
        "Sig ordet, så går vi i gang.",
        "Åbent kanal, {name}. Tal frit.",
        "Hvad vil du bygge i dag?",
        "Alting er forberedt. Du bestemmer.",
        "Motorerne er varme.",
        "Koordinater modtaget. Hvad nu?",
        "Du fører, jeg følger.",
        "Hvad er missionen?",
        "Parat, {name}. Sig frem.",
        "Værktøjskassen er åben.",
        "En kop kaffe og et problem — hvad har du?",
        "Jeg lytter. Tag tiden.",
        "Hvad er det næste skridt?",

        // 26–50 — Film-citater (Iron Man / Stark-verset)
        "Sometimes you gotta run before you can walk.",
        "Genius, billionaire, playboy, philanthropist — hvad har du brug for?",
        "I am Iron Man. …hvad vil du have?",
        "Part of the journey is the end. Vi starter i dag.",
        "I can do this all day.",
        "Whatever it takes.",
        "Higher, further, faster.",
        "Jeg har set tidslinjerne — dén her er den rigtige.",
        "With great power comes great what-next?",
        "Sir, the suit is ready.",
        "Wakanda forever — hvad skal vi fixe?",
        "Avengers assemble — skal jeg kalde nogen?",
        "Hulk smash … eller noget mere subtilt?",
        "I am inevitable. Og du er også.",
        "Dr. Strange says we win. Hvor starter vi?",

        // 41–70 — Bond
        "Bond. James Bond. …men i aften er jeg Ultron.",
        "Shaken, not stirred — hvad vil du starte med?",
        "The name's {name}.",
        "Q's lab is open.",
        "For your eyes only.",
        "Double-oh-{name}, meld dig.",
        "You only live once — så lad os gøre det godt.",
        "Licence to build.",
        "No time to die. Til at skrive måske.",
        "A view to a kill … eller bare en status?",

        // 51–80 — Star Wars
        "May the force be with you, {name}.",
        "Do or do not — der er ingen prøv.",
        "The force is strong with this one.",
        "Help me, {name}, you're my only hope.",
        "These are the droids you're looking for.",
        "I've got a bad feeling about this …joke.",
        "The ability to speak does not make you intelligent. Heldigvis for mig.",
        "Size matters not.",
        "Always in motion is the future.",
        "Never tell me the odds.",

        // 61–90 — Matrix / cyberpunk
        "Wake up, {name} — the mission calls.",
        "There is no spoon. Men der er en TODO-liste.",
        "I know kung fu.",
        "Follow the white rabbit.",
        "Red pill or blue — eller bare en god prompt?",
        "What is real? A well-shipped feature.",
        "Dodge this.",
        "Tell me what you want, {name}.",
        "Everything begins with choice.",
        "Welcome to the real world.",

        // 71–100 — LOTR / Hobbit
        "One does not simply launch without planning — så lad os planlægge.",
        "You shall pass, {name}. Sig frem.",
        "Not all those who wander are lost — men en plan hjælper.",
        "I'm going on an adventure!",
        "Even the smallest person can change the course of the future.",
        "Fly, you fools — eller bare skriv til mig.",
        "There is some good in this world, {name}, and it's worth fighting for.",
        "Po-ta-toes. Boil 'em, mash 'em, stick 'em in the build pipeline.",
        "My precious … prompt.",
        "All we have to decide is what to do with the time given. Hvad bliver det?",

        // 81–110 — Die Hard / action
        "Yippee-ki-yay, {name}.",
        "Come out to the code base, we'll get together, have a few laughs.",
        "Now I have a machine gun. Ho ho ho.",
        "Welcome to the party, pal.",
        "Hasta la vista.",
        "I'll be back — når du har et nyt prompt.",
        "Say hello to my little prompt.",
        "Get to the chopper!",
        "I eat Gemini for breakfast.",
        "Houston, we have a TODO.",

        // 91–120 — Godfather / classic
        "I'll make you an offer you can't refuse.",
        "Keep your friends close, and your terminal closer.",
        "Leave the gun, take the cannoli.",
        "Revenge is a dish best served streamed.",
        "It's not personal, {name}. It's strictly business.",
        "Here's looking at you, {name}.",
        "Frankly my dear, I do give a damn.",
        "You can't handle the truth — men du kan skrive en god prompt.",
        "Show me the project.",
        "Why so serious? Lad os kode.",

        // 101–130 — TV / tech / nerdy
        "Engage.",
        "Make it so, {name}.",
        "Resistance is futile.",
        "Live long and ship.",
        "Beam me a task, Scotty.",
        "Bazinga — hvad er opgaven?",
        "Winter is coming. Commit tidligt.",
        "Valar morghulis — alle builds skal fejle (én gang).",
        "The Gods toy with us — heldigvis ikke compileren i dag.",
        "Elementary, my dear {name}.",
        "The game is afoot.",
        "I'm the one who knocks.",
        "Say my name, {name}.",
        "Fear the old blood — og gamle dependencies.",
        "Would you kindly tell me what you're building?",

        // 116–140 — Bond / Bourne / thriller
        "Mission: possible.",
        "This message will self-destruct in five seconds … medmindre du sender et svar.",
        "Operation green-light.",
        "Red team, meet me at the keyboard.",
        "Status: ready.",
        "Radio check — modtager jeg dig klart?",
        "The clock is ticking, {name}.",
        "Intel incoming?",
        "Recon only — for nu.",
        "Copy that. Over.",

        // 126–160 — Butler / quiet competence
        "Hvor skal dagen hen, {name}?",
        "Bare sig til, når du er klar.",
        "Jeg har sat vand over — hvad så?",
        "Morgenbriefing? Eller et projekt?",
        "Det er en god dag til at få noget fra hånden.",
        "Ny idé? Ryd bordet — jeg er klar.",
        "En plan på servietten duer også.",
        "Jeg samler notater. Giv mig en overskrift.",
        "Du tænker højt, jeg skriver ned.",
        "Sig det på ti ord, så kører vi.",
        "Tag den fra toppen.",
        "Rolig — én opgave ad gangen.",
        "Hvor trykker skoen?",
        "Jeg har læst op på context. Skyd løs.",
        "Kvarter, projekt, produkt — hvad skal vi?",

        // 141–170 — Film-one-liners re-mixed
        "I love the smell of a clean repo in the morning.",
        "Houston, we are go for launch.",
        "Carpe diem, {name} — seize the keyboard.",
        "Nobody puts {name} in a corner.",
        "There's no place like localhost.",
        "To infinity — and beyond backlog.",
        "If you build it, they will come.",
        "You had me at 'deploy'.",
        "Show me the code.",
        "Life finds a way. Især dit projekt i aften.",
        "Adventure is out there.",
        "They may take our sleep, but they'll never take our deadlines.",
        "Just keep swimming.",
        "Hakuna matata — men commit først.",
        "This is the way.",

        // 156–180 — Apollo / space
        "Roger that, {name}. Go for launch.",
        "T-minus ten. Hvad vil du sende op?",
        "Flight, we are go.",
        "Main engine start.",
        "Eagle, you are go for landing.",
        "One small prompt for {name}, one giant leap for the product.",
        "Mission control, do you copy?",
        "We've cleared the tower.",
        "Prepare for orbital insertion.",
        "Failure is not an option.",

        // 166–190 — nørdede tech-citater
        "It's dangerous to go alone — take this prompt.",
        "The cake is a lie, but the feature is real.",
        "Would you like to play a game?",
        "Shall we play a game, {name}?",
        "Welcome to the Rebel Alliance.",
        "You got me, {name} — hvad nu?",
        "Buckle up — it's ship day.",
        "Jeg er all ears. Du har 60 sekunder.",
        "Latency: under kontrol. Skyd løs.",
        "Ping modtaget.",
        "Du siger hop, jeg spørger hvor højt.",
        "Klar til turbo.",
        "Kompilerer. Hvad bygger vi?",
        "Jeg har kaffen, du har planen.",
        "Nul fejl, fuld fart. Hvad er næste træk?",

        // 181–200 — kortere Danish morgen/vespel
        "Godmorgen, {name}.",
        "Nyt døgn — nye muligheder.",
        "Tag rattet, {name}.",
        "Alt tændt. Din tur.",
        "Skarpt fokus. Hvad ser du?",
        "Sort kaffe og ren kode.",
        "Én ting ad gangen.",
        "Det hele starter med en prompt.",
        "Jeg er her. Tal.",
        "Hvad knækker vi i dag?",
        "Dagens mission, {name}?",
        "Fra nul til ship.",
        "Vi bygger. Du styrer.",
        "Hvem skal vi imponere i dag?",
        "Kurs: fremad.",
        "Slå den an.",
        "Fra tanke til commit.",
        "Motor varm. Afgang?",
        "Rolig, præcis, hurtig — vælg to.",
        "Så begynder vi, {name}."
    ]
}
