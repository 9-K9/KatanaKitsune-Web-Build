class_name LanguageCatalog
extends RefCounted

const LANGUAGES := [
	["en", "English"], ["fr", "Français"], ["de", "Deutsch"], ["ja", "日本語"], ["es", "Español"], ["it", "Italiano"],
	["ko", "한국어"], ["zh_CN", "简体中文"], ["hi", "हिन्दी"], ["ar", "العربية"], ["ru", "Русский"], ["tr", "Türkçe"],
	["pt", "Português"], ["ur", "اردو"], ["bn", "বাংলা"], ["sw", "Kiswahili"], ["am", "አማርኛ"], ["ha", "Hausa"],
	["vi", "Tiếng Việt"],
]

static func locale_matches(candidate: String, current: String) -> bool:
	return candidate.replace("-", "_").to_lower() == current.replace("-", "_").to_lower()
