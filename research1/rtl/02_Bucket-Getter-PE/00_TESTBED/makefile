#======================================================
#         Design Flow MakeFile (Author: Marco)
#======================================================
.PHONY: vcs_rtl vcs_gate

#======================================================
#                      Configuration
#======================================================
source_file="file_trace_g16_bfp4.f"
TIMESCALE="-timescale=1ns/1ps"

#======================================================
#                          VCS
#======================================================
VCS_RTL = vcs ${TIMESCALE} \
	-full64 \
	-sverilog \
	-debug_access+all \
	-R \
	+v2k \
	-f ${source_file} \
	+define+SVA \
	+notimingchecks

VCS_GATE = vcs ${TIMESCALE} \
	-full64 \
	-sverilog \
	-debug_access+all \
	-R \
	+v2k \
	-f ${source_file} \
	+neg_tchk \
	+define+SVA \
	+define+GATE

vcs_rtl:
	${VCS_RTL}

vcs_gate:
	${VCS_GATE}
