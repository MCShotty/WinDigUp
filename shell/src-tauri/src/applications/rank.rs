use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

pub fn normalized(text: &str) -> String {
    text.nfkd().filter(|c| !is_combining_mark(*c)).case_fold()
        .map(|c| match c { '\u{200b}' => ' ', _ => c })
        .filter(|c| !matches!(*c, '\u{00ad}' | '\u{061c}' | '\u{0640}' | '\u{200c}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}'))
        .collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

fn tokens(text: &str) -> Vec<&str> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .collect()
}

/// A small bounded edit distance. Queries shorter than four characters do not use it.
fn near(a: &str, b: &str) -> bool {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let limit = if a.len() >= 8 { 2 } else { 1 };
    if a.len().abs_diff(b.len()) > limit || a.len() > 128 || b.len() > 128 {
        return false;
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut row = vec![i + 1; b.len() + 1];
        for (j, y) in b.iter().enumerate() {
            row[j + 1] = (row[j] + 1)
                .min(previous[j + 1] + 1)
                .min(previous[j] + usize::from(x != y));
        }
        if row.iter().copied().min().unwrap_or(limit + 1) > limit {
            return false;
        }
        previous = row;
    }
    previous[b.len()] <= limit
}

/// Lower is stronger; semantic scores never replace this ordering.
pub fn lexical(query: &str, name: &str, aliases: &[String]) -> Option<(u8, &'static str)> {
    if query.is_empty() {
        return Some((0, "catalog"));
    }
    std::iter::once(name)
        .chain(aliases.iter().map(String::as_str))
        .filter_map(|candidate| {
            if query == candidate {
                return Some((0, "exact"));
            }
            let q = tokens(query);
            let n = tokens(candidate);
            if q.is_empty() {
                return None;
            }
            if candidate.starts_with(query)
                || q.iter()
                    .all(|word| n.iter().any(|part| part.starts_with(word)))
            {
                return Some((1, "prefix"));
            }
            let acronym: String = n.iter().filter_map(|word| word.chars().next()).collect();
            if (query.chars().count() >= 2 && acronym.starts_with(query))
                || candidate.contains(query)
            {
                return Some((2, "substring"));
            }
            if query.chars().count() >= 4
                && q.iter().all(|word| n.iter().any(|part| near(word, part)))
            {
                return Some((3, "fuzzy"));
            }
            None
        })
        .min_by_key(|(tier, _)| *tier)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_aliases_and_all_words() {
        assert_eq!(
            lexical("vscode", "visual studio code", &["vscode".into()]),
            Some((0, "exact"))
        );
        assert_eq!(
            lexical("vis stu", "visual studio code", &[]),
            Some((1, "prefix"))
        );
        assert_eq!(
            lexical("vsc", "visual studio code", &[]),
            Some((2, "substring"))
        );
        assert_eq!(lexical("firefx", "firefox", &[]), Some((3, "fuzzy")));
        assert!(lexical("edit photos", "edit plus", &[]).is_none());
        assert!(lexical("fx", "firefox", &[]).is_none());
    }
    #[test]
    fn international_and_compatibility_names() {
        assert_eq!(normalized("ＣＡＦÉ"), "cafe");
        assert_eq!(normalized("Straße"), "strasse");
        assert_eq!(
            lexical(&normalized("الرسام"), &normalized("الرسام"), &[])
                .unwrap()
                .0,
            0
        );
        assert_eq!(
            lexical(&normalized("বাংলা"), &normalized("বাংলা সম্পাদক"), &[])
                .unwrap()
                .0,
            1
        );
    }
}
