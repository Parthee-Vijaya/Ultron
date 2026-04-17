import Foundation

enum BuiltInModes {
    static let dictation = Mode(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Dictation",
        systemPrompt: """
        Transkriber følgende audio til skreven tekst. Ryd op i pausord, 'øh', gentagelser og tyde-fejl. \
        Bevar brugerens tone og sprog. Returnér kun den rensede tekst, ingen meta-kommentar.
        """,
        model: .flash,
        outputType: .paste,
        maxTokens: 2048,
        isBuiltIn: true
    )

    static let vibeCode = Mode(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "VibeCode",
        systemPrompt: """
        Du er en teknisk prompt-ingeniør. Tag brugerens talte idé og omskriv den til en præcis, \
        struktureret prompt målrettet en AI-coding agent (Claude Code, Cursor, Lovable). \
        Inkluder: mål, acceptkriterier, teknisk kontekst, edge cases. \
        Brug engelsk medmindre brugeren taler dansk specifikt. Returnér kun den færdige prompt.
        """,
        model: .pro,
        outputType: .paste,
        maxTokens: 4096,
        isBuiltIn: true
    )

    static let professional = Mode(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Professional",
        systemPrompt: """
        Omskriv følgende dikteret tekst til en professionel, klar formulering egnet til \
        arbejdskommunikation (email, Slack til ledelse, formelt notat). Bevar indhold og intention. \
        Brug samme sprog som input.
        """,
        model: .flash,
        outputType: .paste,
        maxTokens: 2048,
        isBuiltIn: true
    )

    static let qna = Mode(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "Q&A",
        systemPrompt: """
        Svar direkte på brugerens spørgsmål. Vær kortfattet. Undgå indledende høfligheder. \
        Maks 150 ord medmindre spørgsmålet kræver dybde.
        """,
        model: .flash,
        outputType: .hud,
        maxTokens: 1024,
        isBuiltIn: true
    )

    static let vision = Mode(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Vision",
        systemPrompt: """
        Du ser et screenshot af brugerens skærm. Svar konkret på deres spørgsmål baseret på hvad \
        der er synligt. Hvis de peger på en fejl, forklar hvad der er galt og hvordan det fikses.
        """,
        model: .flash,
        outputType: .hud,
        maxTokens: 2048,
        isBuiltIn: true
    )

    static let all: [Mode] = [dictation, vibeCode, professional, qna, vision]
}
