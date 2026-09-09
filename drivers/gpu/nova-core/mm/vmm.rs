// SPDX-License-Identifier: GPL-2.0

//! Virtual Memory Manager for NVIDIA GPU page table management.
//!
//! The [`Vmm`] provides high-level page mapping and unmapping operations for GPU
//! virtual address spaces (Channels, BAR1, BAR2). It wraps the page table walker
//! and handles TLB flushing after modifications.

use kernel::{
    gpu::buddy::AllocatedBlocks,
    maple_tree::MapleTreeAlloc,
    prelude::*, //
};

use core::ops::Range;

use crate::{
    mm::{
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
        VramAddress,
        PAGE_SIZE, //
    },
    num::{
        IntoSafeCast, //
    },
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
    /// Maple tree allocator for virtual address range tracking.
    virt_alloc: Pin<KBox<MapleTreeAlloc<()>>>,
    /// Total number of pages in the virtual address space.
    va_pages: usize,
}

impl Vmm {
    /// Create a new [`Vmm`] for the given Page Directory Base address.
    ///
    /// The [`Vmm`] will manage a virtual address space of `va_size` bytes.
    pub(crate) fn new(
        pdb_addr: VramAddress,
        mmu_version: MmuVersion,
        va_size: u64,
    ) -> Result<Self> {
        let page_size: u64 = PAGE_SIZE.into_safe_cast();
        let va_pages: usize = (va_size / page_size).into_safe_cast();
        let virt_alloc = KBox::pin_init(MapleTreeAlloc::<()>::new(), GFP_KERNEL)?;

        Ok(Self {
            pdb_addr,
            mmu_version,
            page_table_allocs: KVec::new(),
            virt_alloc,
            va_pages,
        })
    }

    /// Allocate a contiguous virtual frame number range.
    ///
    /// # Arguments
    ///
    /// - `num_pages`: Number of pages to allocate.
    /// - `va_range`: `None` = allocate anywhere, `Some(range)` = constrain allocation to the given
    ///   range.
    fn alloc_vfn_range(&self, num_pages: usize, va_range: Option<Range<u64>>) -> Result<Vfn> {
        let page_size: u64 = PAGE_SIZE.into_safe_cast();

        let start_vfn = match va_range {
            Some(r) => {
                let num_pages_u64: u64 = num_pages.into_safe_cast();
                let size = num_pages_u64.checked_mul(page_size).ok_or(EOVERFLOW)?;
                let range_size = r.end.checked_sub(r.start).ok_or(EOVERFLOW)?;
                if range_size != size {
                    return Err(EINVAL);
                }
                let start_vfn: usize = (r.start / page_size).into_safe_cast();
                let end_vfn: usize = (r.end / page_size).into_safe_cast();
                self.virt_alloc
                    .insert_range(start_vfn..end_vfn, (), GFP_KERNEL)?;
                start_vfn
            }
            None => self
                .virt_alloc
                .alloc_range(num_pages, (), ..self.va_pages, GFP_KERNEL)?,
        };

        Ok(Vfn::new(start_vfn.into_safe_cast()))
    }

    /// Free a virtual frame number range back to the maple tree.
    fn free_vfn(&self, vfn: Vfn) {
        let vfn_index: usize = vfn.raw().into_safe_cast();
        if self.virt_alloc.erase(vfn_index).is_none() {
            kernel::pr_warn!("free_vfn: VFN {} not found in maple tree\n", vfn_index);
        }
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
