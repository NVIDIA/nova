// SPDX-License-Identifier: GPL-2.0

//! Virtual Memory Manager for NVIDIA GPU page table management.
//!
//! The [`Vmm`] provides high-level page mapping and unmapping operations for GPU
//! virtual address spaces (Channels, BAR1, BAR2). It wraps the page table walker
//! and handles TLB flushing after modifications.

use kernel::{
    gpu::buddy::AllocatedBlocks,
    prelude::*, //
};

use crate::mm::{
    pagetable::{
        walk::{
            PtWalk,
            WalkResult, //
        },
        MmuVersion, //
    },
    GpuMm,
    Pfn,
    Vfn,
    VramAddress, //
};

/// Virtual Memory Manager for a GPU address space.
///
/// Each [`Vmm`] instance manages a single address space identified by its Page
/// Directory Base (`PDB`) address. The [`Vmm`] is used for Channel, BAR1 and
/// BAR2 mappings.
pub(crate) struct Vmm {
    /// Page Directory Base address for this address space.
    pdb_addr: VramAddress,
    /// MMU version used for page table layout.
    mmu_version: MmuVersion,
    /// Page table allocations required for mappings.
    page_table_allocs: KVec<Pin<KBox<AllocatedBlocks>>>,
}

impl Vmm {
    /// Create a new [`Vmm`] for the given Page Directory Base address.
    pub(crate) fn new(pdb_addr: VramAddress, mmu_version: MmuVersion) -> Result<Self> {
        Ok(Self {
            pdb_addr,
            mmu_version,
            page_table_allocs: KVec::new(),
        })
    }

    /// Read the [`Pfn`] for a mapped [`Vfn`] if one is mapped.
    pub(super) fn read_mapping(&self, mm: &mut GpuMm<'_>, vfn: Vfn) -> Result<Option<Pfn>> {
        let walker = PtWalk::new(self.pdb_addr, self.mmu_version);

        match walker.walk_to_pte(mm, vfn)? {
            WalkResult::Mapped { pfn, .. } => Ok(Some(pfn)),
            WalkResult::Unmapped { .. } | WalkResult::PageTableMissing => Ok(None),
        }
    }
}
