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

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "python"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  '"""Module summary."""',
  "",
  "from package import (",
  "    one,",
  "    two,",
  ")",
  "",
  "GLOBAL: dict[str, int] = {",
  '    "one": 1,',
  "}",
  "",
  "@cached(",
  "    size=2,",
  ")",
  "def outer(",
  "    value: int,",
  ") -> str:",
  '    """',
  "    Function summary.",
  '    """',
  "    ignored = value + 1",
  "",
  "    def inner(item: str) -> None:",
  '        """Inner summary."""',
  "        print(item)",
  "",
  "    return str(ignored)",
  "",
  "",
  "class Example(Base):",
  '    """Class summary."""',
  "    VALUE: tuple[str, ...] = (",
  '        "a",',
  "    )",
  "",
  "    @property",
  "    def result(self) -> int:",
  '        """Result summary."""',
  "        return 42",
  "",
  'if __name__ == "__main__":',
  "    outer(1)",
})

vim.wo.foldmethod = "indent"
vim.wo.foldexpr = "0"
vim.wo.foldtext = "foldtext()"
vim.wo.foldlevel = 7
vim.wo.foldenable = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })

overview.toggle()

eq(vim.wo.foldmethod, "expr", "overview should install expression folding")
eq(vim.wo.foldlevel, 0, "overview should close all structural folds")

local visible = {}
for line = 1, vim.api.nvim_buf_line_count(bufnr) do
  local fold_start = vim.fn.foldclosed(line)
  if fold_start == -1 or fold_start == line then
    visible[#visible + 1] = vim.fn.getline(line)
  end
end

eq(visible, {
  '"""Module summary."""',
  "",
  "from package import (",
  "",
  "GLOBAL: dict[str, int] = {",
  "",
  "@cached(",
  "def outer(",
  "    value: int,",
  ") -> str:",
  "    Function summary.",
  "    def inner(item: str) -> None:",
  '        """Inner summary."""',
  "",
  "",
  "class Example(Base):",
  '    """Class summary."""',
  "    VALUE: tuple[str, ...] = (",
  "",
  "    @property",
  "    def result(self) -> int:",
  '        """Result summary."""',
}, "overview should retain only the structural Python skeleton")

vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
  "",
  "async def added(value: int) -> bool:",
  '    """Added summary."""',
  "    return bool(value)",
})
local added_line = vim.fn.search("^async def added", "nw")
eq(vim.fn.foldclosed(added_line), -1, "an edited-in function signature should become visible")
eq(vim.fn.getline(added_line), "async def added(value: int) -> bool:", "edited text should remain intact")

overview.toggle()
eq(vim.wo.foldmethod, "indent", "toggle should restore the previous fold method")
eq(vim.wo.foldexpr, "0", "toggle should restore the previous fold expression")
eq(vim.wo.foldtext, "foldtext()", "toggle should restore the previous fold text")
eq(vim.wo.foldlevel, 7, "toggle should restore the previous fold level")
eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "toggle should restore the previous cursor")

print("smart_overview: all tests passed")
