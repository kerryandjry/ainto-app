//! Small, deterministic arithmetic parser for launcher instant answers.
//!
//! Supports numbers, parentheses, unary +/- and the binary operators
//! +, -, *, / and ^. A postfix percent is represented as a relative value:
//! multiplication uses the fractional value (`200 * 10% == 20`), while
//! addition/subtraction applies it to the left operand (`200 + 10% == 220`).

#[derive(Debug, Clone, Copy)]
struct Value {
    number: f64,
    is_percent: bool,
}

impl Value {
    fn plain(number: f64) -> Self {
        Self {
            number,
            is_percent: false,
        }
    }
}

struct Parser {
    chars: Vec<char>,
    position: usize,
}

impl Parser {
    fn new(input: &str) -> Self {
        let normalized: String = input
            .trim()
            .chars()
            .map(|character| match character {
                '＝' => '=',
                '０' => '0',
                '１' => '1',
                '２' => '2',
                '３' => '3',
                '４' => '4',
                '５' => '5',
                '６' => '6',
                '７' => '7',
                '８' => '8',
                '９' => '9',
                '＋' => '+',
                '－' | '−' => '-',
                '×' | '＊' => '*',
                '÷' | '／' => '/',
                '（' => '(',
                '）' => ')',
                '％' => '%',
                ',' | '，' => ',',
                other => other,
            })
            .collect();
        Self {
            chars: normalized.trim_start_matches('=').chars().collect(),
            position: 0,
        }
    }

    fn parse(mut self) -> Result<f64, String> {
        self.skip_whitespace();
        if self.position == self.chars.len() {
            return Err("empty expression".into());
        }
        let result = self.expression()?.number;
        self.skip_whitespace();
        if self.position != self.chars.len() {
            return Err("unexpected input".into());
        }
        if result.is_finite() {
            Ok(result)
        } else {
            Err("result is not finite".into())
        }
    }

    fn expression(&mut self) -> Result<Value, String> {
        let mut left = self.term()?;
        loop {
            self.skip_whitespace();
            let operator = match self.peek() {
                Some('+') | Some('-') => self.advance().unwrap(),
                _ => break,
            };
            let right = self.term()?;
            let delta = if right.is_percent {
                left.number * right.number
            } else {
                right.number
            };
            left = Value::plain(if operator == '+' {
                left.number + delta
            } else {
                left.number - delta
            });
        }
        Ok(left)
    }

    fn term(&mut self) -> Result<Value, String> {
        let mut left = self.unary()?;
        loop {
            self.skip_whitespace();
            let operator = match self.peek() {
                Some('*') | Some('/') => self.advance().unwrap(),
                _ => break,
            };
            let right = self.unary()?;
            if operator == '/' && right.number == 0.0 {
                return Err("division by zero".into());
            }
            left = Value::plain(if operator == '*' {
                left.number * right.number
            } else {
                left.number / right.number
            });
        }
        Ok(left)
    }

    fn power(&mut self) -> Result<Value, String> {
        let left = self.postfix()?;
        self.skip_whitespace();
        if self.peek() == Some('^') {
            self.advance();
            let right = self.unary()?;
            Ok(Value::plain(left.number.powf(right.number)))
        } else {
            Ok(left)
        }
    }

    fn unary(&mut self) -> Result<Value, String> {
        self.skip_whitespace();
        match self.peek() {
            Some('+') => {
                self.advance();
                self.unary()
            }
            Some('-') => {
                self.advance();
                let value = self.unary()?;
                Ok(Value {
                    number: -value.number,
                    is_percent: value.is_percent,
                })
            }
            _ => self.power(),
        }
    }

    fn postfix(&mut self) -> Result<Value, String> {
        let mut value = self.primary()?;
        self.skip_whitespace();
        if self.peek() == Some('%') {
            self.advance();
            value.number /= 100.0;
            value.is_percent = true;
        }
        Ok(value)
    }

    fn primary(&mut self) -> Result<Value, String> {
        self.skip_whitespace();
        if self.peek() == Some('(') {
            self.advance();
            let value = self.expression()?;
            self.skip_whitespace();
            if self.advance() != Some(')') {
                return Err("missing closing parenthesis".into());
            }
            return Ok(value);
        }
        self.number().map(Value::plain)
    }

    fn number(&mut self) -> Result<f64, String> {
        self.skip_whitespace();
        let start = self.position;
        let mut saw_digit = false;
        let mut saw_decimal = false;
        while let Some(character) = self.peek() {
            if character.is_ascii_digit() {
                saw_digit = true;
                self.advance();
            } else if character == ',' {
                self.advance();
            } else if character == '.' && !saw_decimal {
                saw_decimal = true;
                self.advance();
            } else {
                break;
            }
        }
        if !saw_digit {
            return Err("expected number".into());
        }
        let raw = self.chars[start..self.position].iter().collect::<String>();
        let mut decimal_parts = raw.split('.');
        let integer = decimal_parts.next().unwrap_or_default();
        let fraction = decimal_parts.next();
        if decimal_parts.next().is_some()
            || fraction.is_some_and(|value| value.contains(','))
            || !valid_integer_grouping(integer)
        {
            return Err("invalid number grouping".into());
        }
        raw.replace(',', "")
            .parse::<f64>()
            .map_err(|_| "invalid number".into())
    }

    fn skip_whitespace(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.advance();
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.position).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let value = self.peek();
        if value.is_some() {
            self.position += 1;
        }
        value
    }
}

fn valid_integer_grouping(value: &str) -> bool {
    if !value.contains(',') {
        return value.chars().all(|character| character.is_ascii_digit());
    }
    let mut groups = value.split(',');
    let first = groups.next().unwrap_or_default();
    if first.is_empty()
        || first.len() > 3
        || !first.chars().all(|character| character.is_ascii_digit())
    {
        return false;
    }
    groups
        .all(|group| group.len() == 3 && group.chars().all(|character| character.is_ascii_digit()))
}

pub fn calculate(expression: &str) -> Result<f64, String> {
    if expression.chars().count() > 512 {
        return Err("expression is too long".into());
    }
    Parser::new(expression).parse()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_result(expression: &str, expected: f64) {
        let actual = calculate(expression).unwrap();
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    #[test]
    fn respects_precedence_and_parentheses() {
        assert_result("1 + 2 * 3", 7.0);
        assert_result("(50 + 25) / 3", 25.0);
    }

    #[test]
    fn supports_unary_and_right_associative_power() {
        assert_result("-2 + 5", 3.0);
        assert_result("2 ^ 3 ^ 2", 512.0);
        assert_result("-2 ^ 2", -4.0);
        assert_result("(-2) ^ 2", 4.0);
        assert_result("2 ^ -2", 0.25);
    }

    #[test]
    fn supports_common_percentage_semantics() {
        assert_result("200 * 10%", 20.0);
        assert_result("200 + 10%", 220.0);
        assert_result("200 - 10%", 180.0);
    }

    #[test]
    fn accepts_full_width_operators_and_grouping_commas() {
        assert_result("（１,０００ ＋ ２００）÷ ４", 300.0);
    }

    #[test]
    fn rejects_invalid_or_non_finite_results() {
        assert!(calculate("1 / 0").is_err());
        assert!(calculate("1 +").is_err());
        assert!(calculate("1,2 + 3").is_err());
        assert!(calculate("12,34 + 3").is_err());
        assert!(calculate("").is_err());
        assert!(calculate(&"1+".repeat(300)).is_err());
    }
}
