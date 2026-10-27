// Decompile functions containing the given addresses (Ghidra headless).
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.util.task.ConsoleTaskMonitor;

public class DumpFuncs extends GhidraScript {
    public void run() throws Exception {
        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();
        for (String a : getScriptArgs()) {
            Address addr = toAddr(Long.parseLong(a, 16));
            Function f = getFunctionContaining(addr);
            if (f == null) { println("=== " + a + ": no function ==="); continue; }
            println("=== " + a + " (" + f.getName() + " @ " + f.getEntryPoint() + ") ===");
            DecompileResults r = dec.decompileFunction(f, 120, mon);
            if (r.decompileCompleted()) println(r.getDecompiledFunction().getC());
            else println("decompile failed: " + r.getErrorMessage());
        }
    }
}
