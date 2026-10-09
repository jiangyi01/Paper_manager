import Foundation
import PaperDeckCore

/// The research-field catalog (PORTABILITY_PLAN §2.4). Ids are append-only; an unknown id falls
/// back (fresh → `general`, legacy → `lifeSciencesCompBio`) in `ConfigResolver`, never crashes.
/// Each field fills the five reader slots of the reading-card prompt (`FieldPreset.cardProfile`),
/// at most 7 starter categories for a new library, suggested alert senders and the example texts
/// of the field-dependent strings (`FieldStrings`).
package enum FieldPresets {
    /// Life sciences & computational biology — today's behavior exactly: the card prompt's reader,
    /// method hint, typical times and checklist examples (`CardPromptProfile.legacyCompBio`), the
    /// starters `PaperCategory.starters`, the 9 sender presets in today's order and today's
    /// example texts.
    package static let lifeSciencesCompBio = FieldPreset(
        id: "lifeSciencesCompBio",
        name: LocalizedText(en: "Life sciences & computational biology", zh: "生命科学与计算生物学"),
        symbol: "leaf",
        readerPattern: "a computational-biology researcher ({level})",
        difficultyPattern: "a comp-bio {stage}",
        methodHint: CardPromptProfile.legacyCompBio.methodHint,
        typicalTimes: CardPromptProfile.legacyCompBio.typicalTimes,
        checklistExamples: CardPromptProfile.legacyCompBio.checklistExamples,
        starterCategories: PaperCategory.starters.map { StarterCategory(name: $0.name, description: $0.description) },
        senderPresetIDs: SenderRule.presets.map(\.id),
        interestsPlaceholder: LocalizedText(
            en: "e.g. single-cell and spatial omics; AI agents for biology",
            zh: "例如：单细胞与空间组学；生物学 AI 智能体"),
        categoryDescriptionExample: LocalizedText(
            en: "Single-cell and spatial transcriptomics methods and atlases",
            zh: "单细胞与空间转录组方法和图谱"),
        categoryPlaceholderExample: LocalizedText(
            en: "Single-cell and spatial omics methods and atlases",
            zh: "单细胞与空间组学方法和图谱"),
        customInstructionsExample: LocalizedText(
            en: "Papers on spatial transcriptomics always count as requests.",
            zh: "空间转录组的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, bioRxiv, arXiv and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、bioRxiv、arXiv 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let neuroCognitive = FieldPreset(
        id: "neuroCognitive",
        name: LocalizedText(en: "Neuroscience & cognitive science", zh: "神经科学与认知科学"),
        symbol: "brain.head.profile",
        readerPattern: "a neuroscience / cognitive-science researcher ({level})",
        difficultyPattern: "a neuroscience {stage}",
        methodHint: "species or participants, n; task or paradigm; recording/imaging method; analyses",
        typicalTimes: "30–60 short report or preprint, 60–120 full article",
        checklistExamples: [
            "Fig. 2: compare the neural responses across conditions; note the effect size",
            "Methods: species or participants, n and the recording or imaging method",
            "Statistics: the test used and how multiple comparisons were handled",
            "Data availability: note the dataset or code repository",
        ],
        starterCategories: [
            StarterCategory(name: "Systems Neuroscience", description: "Neural circuits, population activity and behavior in animal models"),
            StarterCategory(name: "Cognitive & Behavioral", description: "Perception, memory, attention, decision-making and behavior"),
            StarterCategory(name: "Computational Neuroscience", description: "Models and theory of neural computation and learning"),
            StarterCategory(name: "Neuroimaging", description: "fMRI, EEG/MEG and other imaging of brain structure and function"),
            StarterCategory(name: "Neural Development & Disease", description: "Brain development, neurodegeneration and psychiatric disorders"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-biorxiv", "preset-nature", "preset-cell", "preset-ncbi"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. hippocampal memory circuits; computational models of decision-making",
            zh: "例如：海马记忆环路；决策的计算模型"),
        categoryDescriptionExample: LocalizedText(
            en: "Neural circuits and population activity underlying behavior",
            zh: "支撑行为的神经环路与群体活动"),
        categoryPlaceholderExample: LocalizedText(
            en: "Neural circuits and population activity underlying behavior",
            zh: "支撑行为的神经环路与群体活动"),
        customInstructionsExample: LocalizedText(
            en: "Papers on hippocampal replay always count as requests.",
            zh: "海马重放的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, bioRxiv, PubMed and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、bioRxiv、PubMed 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let medicineHealth = FieldPreset(
        id: "medicineHealth",
        name: LocalizedText(en: "Medicine & health", zh: "医学与健康"),
        symbol: "cross.case",
        readerPattern: "a clinical / biomedical researcher ({level})",
        difficultyPattern: "a clinical-research {stage}",
        methodHint: "population and setting, n; design (RCT/cohort/case-control); exposures and outcomes; statistics",
        typicalTimes: "30–60 short report, 60–120 full trial or cohort paper",
        checklistExamples: [
            "Table 1: baseline characteristics of each group",
            "Results: the primary-outcome effect size with its confidence interval",
            "Fig. 1: CONSORT / STROBE flow; note exclusions and losses to follow-up",
            "Methods: note the trial registration number",
        ],
        starterCategories: [
            StarterCategory(name: "Clinical Trials", description: "Randomized and other interventional studies of treatments"),
            StarterCategory(name: "Epidemiology & Public Health", description: "Population studies, risk factors and health policy"),
            StarterCategory(name: "Diagnostics & Imaging", description: "Diagnostic tests, biomarkers and medical imaging"),
            StarterCategory(name: "Health Informatics & AI", description: "Clinical data, prediction models and AI in medicine"),
            StarterCategory(name: "Translational Medicine", description: "From disease mechanisms and models to the clinic"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-medrxiv", "preset-ncbi", "preset-nejm", "preset-jama", "preset-lancet"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. sepsis outcomes; clinical prediction models",
            zh: "例如：脓毒症预后；临床预测模型"),
        categoryDescriptionExample: LocalizedText(
            en: "Randomized trials and cohort studies of cardiovascular treatments",
            zh: "心血管治疗的随机试验和队列研究"),
        categoryPlaceholderExample: LocalizedText(
            en: "Randomized trials and cohort studies of cardiovascular treatments",
            zh: "心血管治疗的随机试验和队列研究"),
        customInstructionsExample: LocalizedText(
            en: "Papers on sepsis trials always count as requests.",
            zh: "脓毒症试验的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, medRxiv, PubMed and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、medRxiv、PubMed 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let csML = FieldPreset(
        id: "csML",
        name: LocalizedText(en: "Computer science & machine learning", zh: "计算机科学与机器学习"),
        symbol: "cpu",
        readerPattern: "a computer-science / machine-learning researcher ({level})",
        difficultyPattern: "a CS/ML {stage}",
        methodHint: "task and data; model or algorithm; training and evaluation setup; baselines",
        typicalTimes: "30–60 workshop or short arXiv paper, 60–120 full conference or journal paper",
        checklistExamples: [
            "Table 2: compare the method with the strongest baseline on each benchmark; note the margin",
            "Sec. 4 Setup: datasets, splits and the evaluation metric",
            "Fig. 3 ablation: which component matters most",
            "Code availability: note the repository",
        ],
        starterCategories: [
            StarterCategory(name: "LLMs & Foundation Models", description: "Large language and multimodal models: pretraining, scaling and adaptation"),
            StarterCategory(name: "Agents & Reasoning", description: "Planning, tool use, reasoning and autonomous agents"),
            StarterCategory(name: "Computer Vision", description: "Image and video understanding, generation and 3D vision"),
            StarterCategory(name: "Language & NLP", description: "Natural language processing tasks, methods and resources"),
            StarterCategory(name: "ML Theory & Optimization", description: "Learning theory, optimization and generalization"),
            StarterCategory(name: "Systems & Efficiency", description: "Training and inference systems, hardware and efficient models"),
            StarterCategory(name: "Evaluation & Safety", description: "Benchmarks, evaluation methods, alignment and robustness"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-arxiv", "preset-acm", "preset-ieee", "preset-openreview",
                          "preset-semantic-scholar"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. LLM agents; efficient inference",
            zh: "例如：LLM 智能体；高效推理"),
        categoryDescriptionExample: LocalizedText(
            en: "Language-model agents, tool use and planning",
            zh: "语言模型智能体、工具调用与规划"),
        categoryPlaceholderExample: LocalizedText(
            en: "Language-model agents, tool use and planning",
            zh: "语言模型智能体、工具调用与规划"),
        customInstructionsExample: LocalizedText(
            en: "Papers on LLM agents always count as requests.",
            zh: "LLM 智能体的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, arXiv and conference alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、arXiv 和会议的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let engineering = FieldPreset(
        id: "engineering",
        name: LocalizedText(en: "Engineering", zh: "工程"),
        symbol: "gearshape.2",
        readerPattern: "an engineering researcher ({level})",
        difficultyPattern: "an engineering {stage}",
        methodHint: "problem and requirements; design or method; experimental or simulation validation; metrics",
        typicalTimes: "30–60 conference paper, 60–120 journal article",
        checklistExamples: [
            "Fig. 2: system diagram; note the inputs, outputs and key components",
            "Sec. 3: design requirements and constraints",
            "Experiments: the test setup and the metrics reported",
            "Table 1: compare performance with prior designs",
        ],
        starterCategories: [
            StarterCategory(name: "Robotics & Control", description: "Robots, autonomous systems and control theory"),
            StarterCategory(name: "Signal Processing", description: "Signals, communications, sensing and estimation"),
            StarterCategory(name: "Electronics & Hardware", description: "Circuits, devices, embedded systems and hardware design"),
            StarterCategory(name: "Mechanical & Civil", description: "Mechanics, structures, materials and infrastructure"),
            StarterCategory(name: "Energy Systems", description: "Power systems, batteries, renewables and energy conversion"),
            StarterCategory(name: "Biomedical Engineering", description: "Medical devices, biomechanics and engineered biological systems"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-arxiv", "preset-ieee"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. legged robots; power electronics",
            zh: "例如：足式机器人；电力电子"),
        categoryDescriptionExample: LocalizedText(
            en: "Control and planning for legged and mobile robots",
            zh: "足式与移动机器人的控制和规划"),
        categoryPlaceholderExample: LocalizedText(
            en: "Control and planning for legged and mobile robots",
            zh: "足式与移动机器人的控制和规划"),
        customInstructionsExample: LocalizedText(
            en: "Papers on legged locomotion always count as requests.",
            zh: "足式运动的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, arXiv and IEEE alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、arXiv 和 IEEE 的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let physicsAstro = FieldPreset(
        id: "physicsAstro",
        name: LocalizedText(en: "Physics & astronomy", zh: "物理与天文"),
        symbol: "atom",
        readerPattern: "a physics or astronomy researcher ({level})",
        difficultyPattern: "a physics {stage}",
        methodHint: "system or sample; theory or model; experimental or numerical setup; key measurements",
        typicalTimes: "30–60 letter or short preprint, 60–120 long article",
        checklistExamples: [
            "Eq. 3: identify the key approximation and its regime of validity",
            "Fig. 2: compare measured and predicted curves; note deviations",
            "Methods: the setup and the error budget",
            "Data availability: note datasets or code",
        ],
        starterCategories: [
            StarterCategory(name: "Condensed Matter", description: "Materials, electronic structure, magnetism and superconductivity"),
            StarterCategory(name: "Quantum Information", description: "Quantum computing, communication and quantum devices"),
            StarterCategory(name: "High-Energy & Particle", description: "Particle physics, field theory and collider experiments"),
            StarterCategory(name: "Astrophysics & Cosmology", description: "Stars, galaxies, cosmology and gravitational waves"),
            StarterCategory(name: "Optics & Photonics", description: "Light, lasers, photonic devices and imaging"),
            StarterCategory(name: "Computational Physics", description: "Simulation methods and numerical studies of physical systems"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-arxiv", "preset-aps", "preset-iop"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. topological materials; exoplanet atmospheres",
            zh: "例如：拓扑材料；系外行星大气"),
        categoryDescriptionExample: LocalizedText(
            en: "Electronic structure and transport in topological materials",
            zh: "拓扑材料中的电子结构与输运"),
        categoryPlaceholderExample: LocalizedText(
            en: "Electronic structure and transport in topological materials",
            zh: "拓扑材料中的电子结构与输运"),
        customInstructionsExample: LocalizedText(
            en: "Papers on moiré superconductivity always count as requests.",
            zh: "莫尔超导的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, arXiv and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、arXiv 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let chemistryMaterials = FieldPreset(
        id: "chemistryMaterials",
        name: LocalizedText(en: "Chemistry & materials", zh: "化学与材料"),
        symbol: "flask",
        readerPattern: "a chemistry / materials-science researcher ({level})",
        difficultyPattern: "a chemistry {stage}",
        methodHint: "materials or compounds; synthesis or simulation; characterization; key measurements",
        typicalTimes: "30–60 communication, 60–120 full article with SI",
        checklistExamples: [
            "Scheme 1: reaction conditions and yields of the key steps",
            "Fig. 2: the characterization (XRD / NMR) supporting the structure",
            "Computational details: functional, basis set and software",
            "SI: note where the raw data are deposited",
        ],
        starterCategories: [
            StarterCategory(name: "Synthesis & Catalysis", description: "New reactions, catalysts and synthetic methods"),
            StarterCategory(name: "Materials & Energy", description: "Functional materials for energy storage, conversion and devices"),
            StarterCategory(name: "Computational Chemistry", description: "Electronic structure, molecular simulation and ML for chemistry"),
            StarterCategory(name: "Analytical & Spectroscopy", description: "Measurement methods, spectroscopy and characterization"),
            StarterCategory(name: "Polymers & Soft Matter", description: "Polymers, colloids, gels and self-assembly"),
            StarterCategory(name: "Electrochemistry", description: "Electrodes, electrolytes, batteries and electrocatalysis"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-chemrxiv", "preset-acs", "preset-rsc"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. photocatalysis; solid-state batteries",
            zh: "例如：光催化；固态电池"),
        categoryDescriptionExample: LocalizedText(
            en: "Catalysts and methods for C–H activation",
            zh: "C–H 活化的催化剂与方法"),
        categoryPlaceholderExample: LocalizedText(
            en: "Catalysts and methods for C–H activation",
            zh: "C–H 活化的催化剂与方法"),
        customInstructionsExample: LocalizedText(
            en: "Papers on solid-state electrolytes always count as requests.",
            zh: "固态电解质的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, ChemRxiv and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、ChemRxiv 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let mathStats = FieldPreset(
        id: "mathStats",
        name: LocalizedText(en: "Mathematics & statistics", zh: "数学与统计"),
        symbol: "function",
        readerPattern: "a mathematics / statistics researcher ({level})",
        difficultyPattern: "a math/stats {stage}",
        methodHint: "setting and assumptions; main theorem or estimator; proof idea or simulation design",
        typicalTimes: "30–60 short note, 60–180 full paper with proofs",
        checklistExamples: [
            "Theorem 2: state the assumptions and what is new",
            "Sec. 3: proof sketch; note the key lemma",
            "Simulation: compare with the baseline estimator",
            "Discussion: list the open problems",
        ],
        starterCategories: [
            StarterCategory(name: "Probability", description: "Random processes, limit theorems and stochastic analysis"),
            StarterCategory(name: "Statistics & Inference", description: "Estimation, testing, Bayesian and causal inference"),
            StarterCategory(name: "Optimization", description: "Continuous and discrete optimization, algorithms and theory"),
            StarterCategory(name: "Applied Mathematics", description: "Differential equations, modeling and applied analysis"),
            StarterCategory(name: "Computational Methods", description: "Numerical analysis, simulation and scientific computing"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-arxiv"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. high-dimensional statistics; stochastic optimization",
            zh: "例如：高维统计；随机优化"),
        categoryDescriptionExample: LocalizedText(
            en: "Estimation and testing in high-dimensional models",
            zh: "高维模型中的估计与检验"),
        categoryPlaceholderExample: LocalizedText(
            en: "Estimation and testing in high-dimensional models",
            zh: "高维模型中的估计与检验"),
        customInstructionsExample: LocalizedText(
            en: "Papers on conformal prediction always count as requests.",
            zh: "共形预测的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar and arXiv alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar 和 arXiv 的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let socialSciences = FieldPreset(
        id: "socialSciences",
        name: LocalizedText(en: "Social sciences", zh: "社会科学"),
        symbol: "person.3",
        readerPattern: "a social-science researcher ({level})",
        difficultyPattern: "a social-science {stage}",
        methodHint: "data and sample; identification or design; measures; main estimates",
        typicalTimes: "30–60 short article, 60–120 full paper or working paper",
        checklistExamples: [
            "Table 2: the main estimates and their robustness checks",
            "Sec. 3: the identification strategy",
            "Data: the source and the sample restrictions",
            "Pre-registration / replication package: note where it is",
        ],
        starterCategories: [
            StarterCategory(name: "Economics", description: "Micro, macro, labor, development and behavioral economics"),
            StarterCategory(name: "Psychology", description: "Social, cognitive, developmental and clinical psychology"),
            StarterCategory(name: "Political Science & Policy", description: "Politics, institutions, public policy and governance"),
            StarterCategory(name: "Sociology & Demography", description: "Social structure, inequality, population and family"),
            StarterCategory(name: "Education", description: "Learning, teaching, schools and education policy"),
            StarterCategory(name: "Methods & Causal Inference", description: "Research design, surveys, experiments and causal methods"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-ssrn", "preset-nber"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. labor markets; causal inference with panel data",
            zh: "例如：劳动力市场；面板数据的因果推断"),
        categoryDescriptionExample: LocalizedText(
            en: "Labor markets, wages and employment policy",
            zh: "劳动力市场、工资与就业政策"),
        categoryPlaceholderExample: LocalizedText(
            en: "Labor markets, wages and employment policy",
            zh: "劳动力市场、工资与就业政策"),
        customInstructionsExample: LocalizedText(
            en: "Papers on minimum-wage effects always count as requests.",
            zh: "最低工资效应的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar, SSRN and NBER alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar、SSRN 和 NBER 的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    package static let humanities = FieldPreset(
        id: "humanities",
        name: LocalizedText(en: "Humanities", zh: "人文学科"),
        symbol: "book.closed",
        readerPattern: "a humanities researcher ({level})",
        difficultyPattern: "a humanities {stage}",
        methodHint: "corpus or sources; theoretical frame; method of reading or analysis",
        typicalTimes: "45–90 article, 120–240 book chapter",
        checklistExamples: [
            "Introduction: the central argument in one sentence",
            "Sec. 2: the main sources used",
            "Engagement: the scholarship the author argues against",
            "Notes: key references to follow",
        ],
        starterCategories: [
            StarterCategory(name: "History", description: "Historical events, periods, sources and historiography"),
            StarterCategory(name: "Literature", description: "Literary texts, criticism and theory"),
            StarterCategory(name: "Philosophy", description: "Ethics, epistemology, metaphysics and the history of ideas"),
            StarterCategory(name: "Linguistics", description: "Language structure, use, change and acquisition"),
            StarterCategory(name: "Art & Media", description: "Visual art, film, music, media and their histories"),
            StarterCategory(name: "Digital Humanities", description: "Computational methods, corpora and digital archives"),
        ],
        senderPresetIDs: ["preset-google-scholar"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. early modern print culture; digital archives",
            zh: "例如：近代早期印刷文化；数字档案"),
        categoryDescriptionExample: LocalizedText(
            en: "Print culture and the history of the book",
            zh: "印刷文化与书籍史"),
        categoryPlaceholderExample: LocalizedText(
            en: "Print culture and the history of the book",
            zh: "印刷文化与书籍史"),
        customInstructionsExample: LocalizedText(
            en: "Papers on early modern print culture always count as requests.",
            zh: "近代早期印刷文化的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    /// Fallback for fresh installs until a field is picked: a field-neutral reader and starters.
    package static let general = FieldPreset(
        id: "general",
        name: LocalizedText(en: "General / other", zh: "通用 / 其他"),
        symbol: "books.vertical",
        readerPattern: "a researcher ({level})",
        difficultyPattern: "a {stage} in the paper's field",
        methodHint: "data or materials, n; approach or model; key analyses",
        typicalTimes: "30–60 short paper, 60–120 long journal article",
        checklistExamples: [
            "Fig. 1 / Table 1: note the main result and its size",
            "Methods: how the data were obtained and analysed",
            "Discussion: list the limitations the authors state",
            "Data/code availability: note any repository or accession",
        ],
        starterCategories: [
            StarterCategory(name: "Methods & Tools", description: "New methods, techniques, software and instruments"),
            StarterCategory(name: "Reviews & Surveys", description: "Reviews, surveys, tutorials and perspectives"),
            StarterCategory(name: "Theory", description: "Theoretical frameworks, models and analysis"),
            StarterCategory(name: "Empirical Studies", description: "Experiments, observations and data-driven findings"),
            StarterCategory(name: "Datasets & Benchmarks", description: "New datasets, resources, benchmarks and evaluations"),
        ],
        senderPresetIDs: ["preset-google-scholar", "preset-arxiv"],
        interestsPlaceholder: LocalizedText(
            en: "e.g. the topics you follow most closely",
            zh: "例如：你最关注的研究主题"),
        categoryDescriptionExample: LocalizedText(
            en: "Methods and tools for analysing the data in my field",
            zh: "我所在领域的数据分析方法与工具"),
        categoryPlaceholderExample: LocalizedText(
            en: "Methods and tools for analysing the data in my field",
            zh: "我所在领域的数据分析方法与工具"),
        customInstructionsExample: LocalizedText(
            en: "Papers my advisor sends always count as requests.",
            zh: "导师发来的论文都算请求"),
        alertsTip: LocalizedText(
            en: "Tip: subscribe your Google Scholar and journal alerts to this address (or forward them to it), then add those senders to the sender list.",
            zh: "提示：把 Google Scholar 和期刊的提醒订阅（或转发）到这个地址，再把这些发件人加入下方的发件人列表。"))

    /// Every field, in picker order (`general` last).
    package static let all: [FieldPreset] = [
        lifeSciencesCompBio, neuroCognitive, medicineHealth, csML, engineering, physicsAstro, chemistryMaterials,
        mathStats, socialSciences, humanities, general,
    ]

    /// The preset for a stored `profile.field` id (unknown or nil → nil).
    package static func preset(id: String?) -> FieldPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
