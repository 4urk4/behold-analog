// Decompile functions at given addresses, creating them if needed.
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.util.task.ConsoleTaskMonitor;

public class DumpAt extends GhidraScript {
    public void run() throws Exception {
        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();
        for (String a : getScriptArgs()) {
            Address addr = toAddr(Long.parseLong(a, 16));
            Function f = getFunctionAt(addr);
            if (f == null) {
                disassemble(addr);
                f = createFunction(addr, null);
            }
            if (f == null) { println("=== " + a + ": cannot create function ==="); continue; }
            println("=== " + a + " (" + f.getName() + " @ " + f.getEntryPoint() + ") ===");
            DecompileResults r = dec.decompileFunction(f, 120, mon);
            if (r.decompileCompleted()) println(r.getDecompiledFunction().getC());
            else println("decompile failed: " + r.getErrorMessage());
        }
    }
}
