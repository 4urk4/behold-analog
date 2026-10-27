// Print pointer values at data addresses and function callers/refs.
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;

public class Refs extends GhidraScript {
    public void run() throws Exception {
        for (String a : getScriptArgs()) {
            Address addr = toAddr(Long.parseLong(a, 16));
            println("== " + addr);
            try {
                long v = getLong(addr);
                println("   qword = 0x" + Long.toHexString(v));
                Function pf = getFunctionContaining(toAddr(v));
                if (pf != null)
                    println("   -> function " + pf.getEntryPoint() + " " + pf.getName());
            } catch (Exception e) {
                println("   read failed: " + e);
            }
            Reference[] refs = getReferencesTo(addr);
            for (Reference r : refs) {
                Address from = r.getFromAddress();
                Function f = getFunctionContaining(from);
                println("   <- " + from + " " + r.getReferenceType()
                        + (f != null ? (" in " + f.getName() + " @" + f.getEntryPoint()) : ""));
            }
        }
    }
}
