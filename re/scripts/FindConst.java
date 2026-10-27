// Find instructions with given immediate constants; print function.
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.program.model.lang.OperandType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;
import java.util.HashSet;
import java.util.Set;

public class FindConst extends GhidraScript {
    public void run() throws Exception {
        Set<Long> vals = new HashSet<>();
        for (String a : getScriptArgs()) vals.add(Long.parseLong(a, 16));
        InstructionIterator it = currentProgram.getListing().getInstructions(true);
        while (it.hasNext()) {
            Instruction ins = it.next();
            boolean hit = false;
            for (int i = 0; i < ins.getNumOperands() && !hit; i++) {
                if ((ins.getOperandType(i) & OperandType.SCALAR) == 0) continue;
                for (Object o : ins.getOpObjects(i)) {
                    if (o instanceof Scalar && vals.contains(((Scalar) o).getUnsignedValue()))
                        hit = true;
                }
            }
            if (!hit) continue;
            Function f = getFunctionContaining(ins.getAddress());
            println(ins.getAddress() + " " + ins + "  | "
                    + (f != null ? (f.getName() + " @" + f.getEntryPoint()) : "?"));
        }
    }
}
