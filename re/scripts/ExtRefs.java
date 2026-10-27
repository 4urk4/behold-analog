// Print references to external symbols by name (e.g. KsStreamPointerAdvance).
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;

public class ExtRefs extends GhidraScript {
    public void run() throws Exception {
        for (String name : getScriptArgs()) {
            println("== " + name);
            SymbolIterator it = currentProgram.getSymbolTable().getSymbols(name);
            int n = 0;
            while (it.hasNext()) {
                Symbol s = it.next();
                Address addr = s.getAddress();
                println("   symbol @ " + addr + " " + s.getSymbolType());
                for (Reference r : getReferencesTo(addr)) {
                    Address from = r.getFromAddress();
                    Function f = getFunctionContaining(from);
                    println("      <- " + from + " " + r.getReferenceType()
                            + (f != null ? (" in " + f.getName() + " @" + f.getEntryPoint()) : ""));
                    n++;
                }
            }
            if (n == 0) println("   (no refs)");
        }
    }
}
