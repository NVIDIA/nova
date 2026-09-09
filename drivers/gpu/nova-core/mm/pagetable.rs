// SPDX-License-Identifier: GPL-2.0

//! Common page table types shared between MMU v2 and v3.
//!
//! This module provides foundational types used by both MMU versions:
//! - Page table level hierarchy
//! - Memory aperture types for PDEs and PTEs

#![expect(dead_code)]

use kernel::num::Bounded;

use crate::gpu::Architecture;

/// Extracts the page table index at a given level from a virtual address.
pub(super) trait VaLevelIndex {
    /// Return the page table index at `level` for this virtual address.
    fn level_index(&self, level: u64) -> u64;
}

/// MMU version enumeration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MmuVersion {
    /// MMU v2 for Turing/Ampere/Ada.
    V2,
    /// MMU v3 for Hopper and later.
    V3,
}

impl From<Architecture> for MmuVersion {
    fn from(arch: Architecture) -> Self {
        match arch {
            Architecture::Turing | Architecture::Ampere | Architecture::Ada => Self::V2,
            Architecture::Hopper | Architecture::BlackwellGB10x | Architecture::BlackwellGB20x => {
                Self::V3
            }
        }
    }
}

/// Page Table Level hierarchy for MMU v2/v3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PageTableLevel {
    /// Level 0 - Page Directory Base (root).
    Pdb,
    /// Level 1 - Intermediate page directory.
    L1,
    /// Level 2 - Intermediate page directory.
    L2,
    /// Level 3 - Intermediate page directory or dual PDE (version-dependent).
    L3,
    /// Level 4 - PTE level for v2, intermediate page directory for v3.
    L4,
    /// Level 5 - PTE level used for MMU v3 only.
    L5,
}

impl PageTableLevel {
    /// Number of entries per page table (512 for 4KB pages).
    pub(super) const ENTRIES_PER_TABLE: usize = 512;

    /// Get the next level in the hierarchy.
    pub(super) const fn next(&self) -> Option<PageTableLevel> {
        match self {
            Self::Pdb => Some(Self::L1),
            Self::L1 => Some(Self::L2),
            Self::L2 => Some(Self::L3),
            Self::L3 => Some(Self::L4),
            Self::L4 => Some(Self::L5),
            Self::L5 => None,
        }
    }

    /// Convert level to index.
    pub(super) const fn as_index(&self) -> u64 {
        match self {
            Self::Pdb => 0,
            Self::L1 => 1,
            Self::L2 => 2,
            Self::L3 => 3,
            Self::L4 => 4,
            Self::L5 => 5,
        }
    }
}

/// Memory aperture for Page Table Entries (`PTE`s).
///
/// Determines which memory region the `PTE` points to.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum AperturePte {
    /// Local video memory (VRAM).
    #[default]
    VideoMemory = 0,
    /// Peer GPU's video memory.
    PeerMemory = 1,
    /// System memory with cache coherence.
    SystemCoherent = 2,
    /// System memory without cache coherence.
    SystemNonCoherent = 3,
}

// TODO[FPRI]: Replace with `#[derive(FromPrimitive)]` when available.
impl From<Bounded<u64, 2>> for AperturePte {
    fn from(val: Bounded<u64, 2>) -> Self {
        match *val {
            0 => Self::VideoMemory,
            1 => Self::PeerMemory,
            2 => Self::SystemCoherent,
            3 => Self::SystemNonCoherent,
            _ => Self::VideoMemory,
        }
    }
}

// TODO[FPRI]: Replace with `#[derive(ToPrimitive)]` when available.
impl From<AperturePte> for Bounded<u64, 2> {
    fn from(val: AperturePte) -> Self {
        Bounded::from_expr(val as u64 & 0x3)
    }
}

/// Memory aperture for Page Directory Entries (`PDE`s).
///
/// Note: For `PDE`s, `Invalid` (0) means the entry is not valid.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum AperturePde {
    /// Invalid/unused entry.
    #[default]
    Invalid = 0,
    /// Page table is in video memory.
    VideoMemory = 1,
    /// Page table is in system memory with coherence.
    SystemCoherent = 2,
    /// Page table is in system memory without coherence.
    SystemNonCoherent = 3,
}

// TODO[FPRI]: Replace with `#[derive(FromPrimitive)]` when available.
impl From<Bounded<u64, 2>> for AperturePde {
    fn from(val: Bounded<u64, 2>) -> Self {
        match *val {
            1 => Self::VideoMemory,
            2 => Self::SystemCoherent,
            3 => Self::SystemNonCoherent,
            _ => Self::Invalid,
        }
    }
}

// TODO[FPRI]: Replace with `#[derive(ToPrimitive)]` when available.
impl From<AperturePde> for Bounded<u64, 2> {
    fn from(val: AperturePde) -> Self {
        Bounded::from_expr(val as u64 & 0x3)
    }
}
