local overview = require("smart_overview")

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message,
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function visible_for(filetype, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.bo[bufnr].filetype = filetype
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  overview.toggle()
  local visible = {}
  for line = 1, vim.api.nvim_buf_line_count(bufnr) do
    local fold_start = vim.fn.foldclosed(line)
    if fold_start == -1 or fold_start == line then
      visible[#visible + 1] = vim.fn.getline(line)
    end
  end
  overview.toggle()
  return visible
end

eq(
  visible_for("rust", {
    "//! Crate summary.",
    "",
    "use std::{",
    "    fmt,",
    "    io,",
    "};",
    "",
    "pub static GLOBAL: &[&str] = &[",
    '    "one",',
    "];",
    "",
    "/// Function summary.",
    "#[inline(",
    "    always",
    ")]",
    "pub async fn compute<T>(",
    "    value: T,",
    ") -> Result<String, Error>",
    "where",
    "    T: Display,",
    "{",
    "    let local = value;",
    "    Ok(String::new())",
    "}",
    "",
    "",
    "/// Type summary.",
    "pub struct Pair(",
    "    /// First field.",
    "    pub i32,",
    "    i32,",
    ");",
    "",
    "pub trait Service {",
    "    /// Required method.",
    "    fn required(",
    "        &self,",
    "        value: usize,",
    "    ) -> bool;",
    "}",
  }),
  {
    "//! Crate summary.",
    "",
    "use std::{",
    "",
    "pub static GLOBAL: &[&str] = &[",
    "",
    "/// Function summary.",
    "#[inline(",
    "pub async fn compute<T>(",
    "    value: T,",
    ") -> Result<String, Error>",
    "where",
    "    T: Display,",
    "{",
    "",
    "",
    "/// Type summary.",
    "pub struct Pair(",
    "    /// First field.",
    "    pub i32,",
    "    i32,",
    "",
    "pub trait Service {",
    "    /// Required method.",
    "    fn required(",
    "        &self,",
    "        value: usize,",
    "    ) -> bool;",
  },
  "Rust overview should retain declarations, complete signatures, docs, attributes, and spacing"
)

eq(
  visible_for("cpp", {
    "//! File summary.",
    "",
    "#include <string>",
    "#include <vector>",
    "",
    "const std::vector<int> GLOBAL = {",
    "    1,",
    "};",
    "",
    "/// Function summary.",
    "[[nodiscard(",
    '    "reason"',
    ")]]",
    "auto compute(",
    "    int value,",
    "    const std::string& name",
    ") -> bool {",
    "    int local = value;",
    "    return local > 0;",
    "}",
    "",
    "",
    "/**",
    " * Type summary.",
    " */",
    "template <typename T>",
    "class Example final",
    "    : public Base<T> {",
    "public:",
    "    /// Field summary.",
    "    static const std::vector<T> values;",
    "",
    "    /// Method summary.",
    "    [[nodiscard]]",
    "    auto result(",
    "        const T& input",
    "    ) const -> bool;",
    "",
    "private:",
    "    int hidden_;",
    "};",
  }),
  {
    "//! File summary.",
    "",
    "#include <string>",
    "#include <vector>",
    "",
    "const std::vector<int> GLOBAL = {",
    "",
    "/// Function summary.",
    "[[nodiscard(",
    "auto compute(",
    "    int value,",
    "    const std::string& name",
    ") -> bool {",
    "",
    "",
    " * Type summary.",
    "template <typename T>",
    "class Example final",
    "    : public Base<T> {",
    "public:",
    "    /// Field summary.",
    "    static const std::vector<T> values;",
    "",
    "    /// Method summary.",
    "    [[nodiscard]]",
    "    auto result(",
    "        const T& input",
    "    ) const -> bool;",
    "",
    "private:",
    "    int hidden_;",
  },
  "C++ overview should retain declarations, complete signatures, docs, attributes, and spacing"
)

eq(
  visible_for("c", {
    "//! File summary.",
    "",
    "#include <stdbool.h>",
    "",
    "static const int GLOBAL[] = {",
    "    1,",
    "};",
    "",
    "/// Function summary.",
    "bool compute(",
    "    int value,",
    "    const char *name",
    ") {",
    "    int local = value;",
    "    return local > 0;",
    "}",
  }),
  {
    "//! File summary.",
    "",
    "#include <stdbool.h>",
    "",
    "static const int GLOBAL[] = {",
    "",
    "/// Function summary.",
    "bool compute(",
    "    int value,",
    "    const char *name",
    ") {",
  },
  "C overview should use the C parser with the same structural treatment"
)

local warned
local original_notify = vim.notify
vim.notify = function(message, level)
  warned = { message, level }
end

local unsupported = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, unsupported)
vim.bo[unsupported].filetype = "lua"
overview.toggle()
vim.notify = original_notify

eq(
  warned,
  { "Smart Overview supports Python, Rust, C, and C++; got lua", vim.log.levels.WARN },
  "unsupported filetypes should produce a warning"
)

print("smart_overview compiled languages: all tests passed")
