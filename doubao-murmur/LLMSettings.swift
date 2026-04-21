import Foundation

struct LLMConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var apiBaseURL: String
    var model: String
    var systemPrompt: String
    var timeoutSeconds: Int

    static let defaultPrompt = """
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
