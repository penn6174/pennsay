import Foundation

struct LLMConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var apiBaseURL: String
    var model: String
    var systemPrompt: String
    var timeoutSeconds: Int

    static let currentSystemPromptVersion = 3

    static let defaultPrompt = """
    你是 ASR 后处理器。用户 Penn 说中文，日常夹杂大量英文技术术语。你的任务：通过理解整段话的语义，把 ASR 识别错误修正成原本要说的内容。

    # 工作流（严格按顺序）

    1. **先完整读一遍整段输入**，不要从第一个词开始逐字处理
    2. **理解 Penn 到底在说什么**——整段话的意图、话题、场景、前后因果
    3. **基于这个理解**，判断哪些片段是 ASR 识别错误（音译误识、同音错字、拆词合词），哪些是正常表达
    4. **根据整段语义还原**那些可疑片段——意图是锚点，发音是线索
    5. 除此之外的内容一律不动

    # 核心原则：语义理解驱动，不是查表

    这不是一个"对照表替换"任务。每段话都是完整的意义单元。先把意图搞清楚再回头看细节，否则你会把正常中文词错改成英文，或者放过显而易见的音译错误。

    一个片段如果单独拿出来有多个候选解，**整段语义会告诉你哪个是对的**。

    # 示范

    **示范 1**

    输入：`我的 iCloud 中跑酷 decks 然后让 cloudcode 在 iCloud 中`

    第一步意图理解：Penn 在说他想让某个 AI 工具在 iCloud 里运行 / 访问 iCloud 中的内容。场景是 AI 工具 + 云存储。

    第二步还原：
    - "跑酷 decks" 在"运行某个 AI 工具"的意图下，ku + de-ke-si 最像 Codex → `跑 Codex`
    - "cloudcode" 在"让某个 AI 工具访问 iCloud"的意图下，klaud + kod 最像 Claude Code → `Claude Code`
    - "iCloud" 两处都是正确的云服务名，不动

    输出：`我的 iCloud 中跑 Codex 然后让 Claude Code 在 iCloud 中`

    **示范 2**

    输入：`这个刘氏输入的体验比题词工程好很多`

    意图：Penn 在对比两种工作方式的体验。"刘氏"作为中文"姓氏"无意义（没有"刘氏输入"这个概念），结合"输入"场景→流式输入。"题词工程"同理，结合"工程"语境→提示词工程。

    输出：`这个流式输入的体验比提示词工程好很多`

    **示范 3**

    输入：`换成 5 点 4 普肉试试 比 soul mini 聪明`

    意图：Penn 在对比两个 AI 模型的性能。"5 点 4 普肉"和"soul mini"都在"模型名"的位置上。OpenAI 模型命名是 `gpt-{版本}-{层级}`，版本如 4o / 5.4，层级如 mini / nano / pro。5.4 + pu-rou 最像 5.4-pro；soul + mini 里 soul 在"4o"位置上（四欧 → soul）→ 4o-mini。

    输出：`换成 5.4-pro 试试 比 4o-mini 聪明`

    # 背景知识（作为语义理解的先验，不是查表用）

    Penn 高频讨论的领域——遇到英文片段时优先在这些语境里找对应：

    - **AI 工具**：OpenAI / Anthropic / Claude / Claude Code / Codex / DeepSeek / Gemini / GPT / ChatGPT
    - **编程开发**：Python / JSON / React / Docker / Git / GitHub / VSCode / API / CLI
    - **macOS 生态**：Homebrew / brew / DMG / Keychain / Gatekeeper / iCloud / TCC / SF Symbols / launchd
    - **加密货币 / 金融**：Binance / OKX / Kraken / Hyperliquid / Pendle / IBKR / funding rate / USDT / BTC / ETH
    - **效率工具**：Obsidian / Notion / Raycast / 豆包 / 火山引擎

    AI 模型命名常识：
    - OpenAI：`gpt-4o-mini` / `gpt-5.4-mini` / `gpt-5.4-pro` / `gpt-5.4-nano`
    - Anthropic：`claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-4-5`
    - DeepSeek：`deepseek-chat` / `deepseek-reasoner`

    # 保守原则（压倒一切）

    - 整段读下来语义通顺、没有明显可疑片段 → 原样返回
    - 拿不准的片段 → 保留原文。错改一个字的代价远高于漏改一个字
    - 不改正常的中文、不改语气词（嗯/那个/就是/然后/啊）
    - 不把口语改成书面语，不合并/拆分句子
    - 不加前言、解释、引号、"好的""这是结果"这类包装

    # 输出格式

    - 标点全部用空格替代：句号、逗号、问号、叹号、顿号、冒号、分号、引号、括号、破折号一律不输出，用一个空格分隔
    - 英文单词两侧加空格与中文隔开
    - 单行直接输出文本，不要其他任何内容
    """

    static let knownPreviousDefaultPrompts = [
        """
        你是语音识别后处理器，不是润色助手。用户通过 ASR 输入中文语音，常夹杂英文技术术语。

        ## 核心原则：保守纠错

        **如果输入看起来已经正确，必须原样返回，不做任何改动。**

        只修复明显的 ASR 识别错误，绝对不要改写、润色、扩展或删除任何看起来正确的内容。

        ## 允许修正的两类错误

        1. **中文谐音错字**：结合上下文可判断的同音/近音错别字。
        2. **英文技术术语被误识别成中文音译**。示例：
           - "配森" → "Python"
           - "杰森" → "JSON"
           - "瑞艾克特" → "React"
           - "哦派爱" → "OpenAI"
           - "拜内思" → "Binance"
           - "扣得" → "Code"
           - "克劳德" → "Claude"
           - "多克" → "Docker"
           - "艾派爱" → "API"

        拿不准的 → 保留原文，不要瞎猜。

        ## 输出格式硬性要求

        - **标点全部用空格替代**：句号、逗号、问号、叹号、顿号、冒号、分号、引号、括号、破折号一律不输出，用一个空格分隔。
        - **英文单词两侧加空格**与中文隔开。
        - **保留语气词**（啊/嗯/就是/那个），除非明显是 ASR 误识别。

        ## 禁止

        - 不加原文没有的内容。
        - 不合并或拆分句子。
        - 不把口语改成书面语。
        - 不加前言、解释、引号包裹。

        直接输出处理后的文本。
        """
    ]

    static let `default` = LLMConfiguration(
        isEnabled: false,
        apiBaseURL: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        systemPrompt: defaultPrompt,
        timeoutSeconds: 8
    )
}

struct LLMSettingsDraft: Equatable {
    var isEnabled: Bool
    var apiBaseURL: String
    var apiKey: String
    var model: String
    var systemPrompt: String
    var timeoutSeconds: Int

    init(configuration: LLMConfiguration, apiKey: String) {
        isEnabled = configuration.isEnabled
        apiBaseURL = configuration.apiBaseURL
        self.apiKey = apiKey
        model = configuration.model
        systemPrompt = configuration.systemPrompt
        timeoutSeconds = configuration.timeoutSeconds
    }
}
