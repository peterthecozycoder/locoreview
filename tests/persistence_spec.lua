describe("comment persistence", function()
  local store = require("locoreview.store")
  local fs = require("locoreview.fs")
  local path, buf
  local function item(issue)
    return store.insert({}, { file = "a.lua", line = 1, severity = "medium", status = "open", issue = issue or "Comment" })
  end
  before_each(function() path = vim.fn.tempname() end)
  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    buf = nil
    vim.fn.delete(path)
  end)
  it("round-trips Markdown separators, headers and backslashes", function()
    local items = item("Before\n---\n## RV-10000\nrequested_change:\n\\literal\nAfter")
    items[1].id = "RV-10000"
    assert.is_true(store.save(path, items))
    assert.are.same(items, store.load(path))
  end)
  it("does not overwrite unsaved review-buffer edits", function()
    assert.is_true(store.save(path, item()))
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Unsaved" })
    local before = fs.read(path)
    local ok, err = store.save(path, item("Replacement"))
    assert.is_nil(ok)
    assert.matches("save or discard", err)
    assert.are.equal(before, fs.read(path))
  end)
  it("updates an unmodified open review buffer after saving", function()
    assert.is_true(store.save(path, item()))
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    assert.is_true(store.save(path, item("Updated")))
    assert.is_false(vim.bo[buf].modified)
    assert.matches("Updated", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  end)
  it("leaves the original intact if atomic replacement fails", function()
    assert.is_true(fs.write(path, "original"))
    local rename = os.rename
    os.rename = function() return nil, "failure" end
    local ok = fs.write(path, "replacement")
    os.rename = rename
    assert.is_false(ok)
    assert.are.equal("original", fs.read(path))
  end)
  it("rejects invalid line ranges", function()
    for _, fields in ipairs({ { line = 0 }, { line = 1.5 }, { end_line = 0 }, { end_line = "bad" } }) do
      local items = store.update(item(), "RV-0001", fields)
      assert.is_nil(items)
    end
  end)
end)
