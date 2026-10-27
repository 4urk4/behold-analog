// Find string data matching needles, print their references and containing
// functions, then dump the function list. Ghidra headless post-script.
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.util.HashSet;
import java.util.Set;

public class FindStrRefs extends GhidraScript {
    Set<Address> seen = new HashSet<>();

    public void run() throws Exception {
        String[] needles = getScriptArgs();
        if (needles.length == 0)
            needles = new String[] { "AVIS", "Crossbar", "Capture", "Preferred Video",
                                     "TV Audio", "TV Tuner", "Audio" };
        int count = 0;
        DataIterator it = currentProgram.getListing().getDefinedData(true);
        while (it.hasNext()) {
            Data d = it.next();
            Object v;
            try { v = d.getValue(); } catch (Exception e) { continue; }
            if (!(v instanceof String)) continue;
            String s = (String) v;
            boolean hit = false;
            for (String n : needles)
                if (s.toLowerCase().contains(n.toLowerCase())) { hit = true; break; }
            if (!hit) continue;
            count++;
            println("STR @ " + d.getAddress() + " : " + s.replace("\n", "\\n"));
            printRefs(d.getAddress(), 0);
        }
        println("== " + count + " string matches ==");
        println("== functions ==");
        for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
            println("FUNC " + f.getEntryPoint() + " " + f.getName()
                    + " size=" + f.getBody().getNumAddresses());
        }
    }

    private void printRefs(Address target, int depth) {
        if (depth > 1 || !seen.add(target)) return;
        Reference[] refs = getReferencesTo(target);
        if (refs.length == 0) {
            println("    (no refs)");
            return;
        }
        for (Reference r : refs) {
            Address from = r.getFromAddress();
            Function f = getFunctionContaining(from);
            println("    <- " + from + " " + r.getReferenceType()
                    + (f != null ? (" in " + f.getName() + " @" + f.getEntryPoint()) : ""));
            if (f == null) printRefs(from, depth + 1);
        }
    }
}
