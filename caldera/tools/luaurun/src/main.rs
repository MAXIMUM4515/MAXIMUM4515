use mlua::prelude::*;
use std::fs;

// Tiny Luau runner for the offline tests.
//   luaurun <file.luau>        run a file with a `__loadfile(path)` global (tests/harness.luau builds `require` on it)
//   luaurun --check <files..>  compile only, reporting syntax errors from the real Luau compiler
fn main() -> LuaResult<()> {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).expect("usage: luaurun <file.luau> | --check <files...>");
    let lua = Lua::new();
    if path == "--check" {
        // Compile only: reports syntax errors from the real Luau compiler without running anything.
        let mut failed = false;
        for file in &args[2..] {
            let src = fs::read_to_string(file).expect("read");
            if let Err(e) = lua.load(&src).set_name(file).into_function() {
                eprintln!("{}", e);
                failed = true;
            }
        }
        std::process::exit(if failed { 1 } else { 0 });
    }
    let globals = lua.globals();
    let loader = lua.create_function(|lua, p: String| {
        let src = fs::read_to_string(&p).map_err(|e| LuaError::RuntimeError(format!("{}: {}", p, e)))?;
        lua.load(&src).set_name(&p).eval::<LuaValue>()
    })?;
    globals.set("__loadfile", loader)?;
    let src = fs::read_to_string(path).expect("read");
    lua.load(&src).set_name(path).exec()
}
