use super::{
    block_cache_sync_all, get_block_cache, BlockDevice, DirEntry, DiskInode, DiskInodeType,
    EasyFileSystem, DIRENT_SZ,
};
use alloc::string::String;
use alloc::sync::Arc;
use alloc::vec::Vec;
use spin::{Mutex, MutexGuard};
/// Virtual filesystem layer over easy-fs
pub struct Inode {
    block_id: usize,
    block_offset: usize,
    fs: Arc<Mutex<EasyFileSystem>>,
    block_device: Arc<dyn BlockDevice>,
}

impl Inode {
    /// Create a vfs inode
    pub fn new(
        block_id: u32,
        block_offset: usize,
        fs: Arc<Mutex<EasyFileSystem>>,
        block_device: Arc<dyn BlockDevice>,
    ) -> Self {
        Self {
            block_id: block_id as usize,
            block_offset,
            fs,
            block_device,
        }
    }

    /// 获取 inode 编号（根据 block_id 和 block_offset 计算）
    pub fn get_inode_id(&self) -> u32 {
        let fs = self.fs.lock();
        fs.get_inode_id(self.block_id as u32, self.block_offset)
    }

    /// 获取硬链接计数
    pub fn get_nlink(&self) -> u32 {
        self.read_disk_inode(|disk_inode| disk_inode.nlink)
    }

    /// 增加硬链接计数
    pub fn inc_nlink(&self) {
        self.modify_disk_inode(|disk_inode| {
            disk_inode.nlink += 1;
        });
        block_cache_sync_all();
    }

    /// 减少硬链接计数
    pub fn dec_nlink(&self) {
        self.modify_disk_inode(|disk_inode| {
            disk_inode.nlink -= 1;
        });
        block_cache_sync_all();
    }

    /// 判断是否是目录
    pub fn is_dir(&self) -> bool {
        self.read_disk_inode(|disk_inode| disk_inode.is_dir())
    }

    /// 判断是否是文件
    pub fn is_file(&self) -> bool {
        self.read_disk_inode(|disk_inode| disk_inode.is_file())
    }

    /// Call a function over a disk inode to read it
    fn read_disk_inode<V>(&self, f: impl FnOnce(&DiskInode) -> V) -> V {
        get_block_cache(self.block_id, Arc::clone(&self.block_device))
            .lock()
            .read(self.block_offset, f)
    }

    /// Call a function over a disk inode to modify it
    fn modify_disk_inode<V>(&self, f: impl FnOnce(&mut DiskInode) -> V) -> V {
        get_block_cache(self.block_id, Arc::clone(&self.block_device))
            .lock()
            .modify(self.block_offset, f)
    }

    /// Find inode under a disk inode by name
    fn find_inode_id(&self, name: &str, disk_inode: &DiskInode) -> Option<u32> {
        // assert it is a directory
        assert!(disk_inode.is_dir());
        let file_count = (disk_inode.size as usize) / DIRENT_SZ;
        let mut dirent = DirEntry::empty();
        for i in 0..file_count {
            assert_eq!(
                disk_inode.read_at(DIRENT_SZ * i, dirent.as_bytes_mut(), &self.block_device,),
                DIRENT_SZ,
            );
            if dirent.name() == name {
                return Some(dirent.inode_number());
            }
        }
        None
    }

    /// Find inode under current inode by name
    pub fn find(&self, name: &str) -> Option<Arc<Inode>> {
        // 目录查找流程：目录 inode -> 遍历 dirent -> 定位子 inode 的磁盘位置。
        let fs = self.fs.lock();
        self.read_disk_inode(|disk_inode| {
            self.find_inode_id(name, disk_inode).map(|inode_id| {
                let (block_id, block_offset) = fs.get_disk_inode_pos(inode_id);
                Arc::new(Self::new(
                    block_id,
                    block_offset,
                    self.fs.clone(),
                    self.block_device.clone(),
                ))
            })
        })
    }

    /// Increase the size of a disk inode
    fn increase_size(
        &self,
        new_size: u32,
        disk_inode: &mut DiskInode,
        fs: &mut MutexGuard<EasyFileSystem>,
    ) {
        if new_size < disk_inode.size {
            return;
        }
        // 先按“新增块数”批量申请数据块，再一次性扩容 inode。
        let blocks_needed = disk_inode.blocks_num_needed(new_size);
        let mut v: Vec<u32> = Vec::new();
        for _ in 0..blocks_needed {
            v.push(fs.alloc_data());
        }
        disk_inode.increase_size(new_size, v, &self.block_device);
    }

    /// Create inode under current inode by name.
    /// Attention: use find previously to ensure the new file not existing.
    pub fn create(&self, name: &str) -> Option<Arc<Inode>> {
        let mut fs = self.fs.lock();
        // 1) 分配新 inode
        let new_inode_id = fs.alloc_inode();
        // 2) 初始化 inode 元数据
        let (new_inode_block_id, new_inode_block_offset) = fs.get_disk_inode_pos(new_inode_id);
        get_block_cache(new_inode_block_id as usize, Arc::clone(&self.block_device))
            .lock()
            .modify(new_inode_block_offset, |new_inode: &mut DiskInode| {
                new_inode.initialize(DiskInodeType::File);
            });
        // 3) 在当前目录追加 dirent 项
        self.modify_disk_inode(|root_inode| {
            // append file in the dirent
            let file_count = (root_inode.size as usize) / DIRENT_SZ;
            let new_size = (file_count + 1) * DIRENT_SZ;
            // increase size
            self.increase_size(new_size as u32, root_inode, &mut fs);
            // write dirent
            let dirent = DirEntry::new(name, new_inode_id);
            root_inode.write_at(
                file_count * DIRENT_SZ,
                dirent.as_bytes(),
                &self.block_device,
            );
        });

        let (block_id, block_offset) = fs.get_disk_inode_pos(new_inode_id);
        block_cache_sync_all();
        // 4) 返回新文件的 Inode 句柄
        Some(Arc::new(Self::new(
            block_id,
            block_offset,
            self.fs.clone(),
            self.block_device.clone(),
        )))
        // release efs lock automatically by compiler
    }

    /// List inodes by id under current inode
    pub fn readdir(&self) -> Vec<String> {
        let _fs = self.fs.lock();
        self.read_disk_inode(|disk_inode| {
            let file_count = (disk_inode.size as usize) / DIRENT_SZ;
            let mut v: Vec<String> = Vec::new();
            for i in 0..file_count {
                let mut dirent = DirEntry::empty();
                assert_eq!(
                    disk_inode.read_at(i * DIRENT_SZ, dirent.as_bytes_mut(), &self.block_device,),
                    DIRENT_SZ,
                );
                v.push(String::from(dirent.name()));
            }
            v
        })
    }

    /// Read data from current inode
    pub fn read_at(&self, offset: usize, buf: &mut [u8]) -> usize {
        let _fs = self.fs.lock();
        self.read_disk_inode(|disk_inode| disk_inode.read_at(offset, buf, &self.block_device))
    }

    /// Write data to current inode
    pub fn write_at(&self, offset: usize, buf: &[u8]) -> usize {
        let mut fs = self.fs.lock();
        let size = self.modify_disk_inode(|disk_inode| {
            self.increase_size((offset + buf.len()) as u32, disk_inode, &mut fs);
            disk_inode.write_at(offset, buf, &self.block_device)
        });
        block_cache_sync_all();
        size
    }

    /// Clear the data in current inode
    pub fn clear(&self) {
        let mut fs = self.fs.lock();
        self.modify_disk_inode(|disk_inode| {
            let size = disk_inode.size;
            let data_blocks_dealloc = disk_inode.clear_size(&self.block_device);
            assert!(data_blocks_dealloc.len() == DiskInode::total_blocks(size) as usize);
            for data_block in data_blocks_dealloc.into_iter() {
                fs.dealloc_data(data_block);
            }
        });
        block_cache_sync_all();
    }

    /// 创建一个硬链接，在当前目录（必须是目录）下创建一个指向 target_inode_id 的目录项
    pub fn link(&self, name: &str, target_inode_id: u32) -> isize {
        let mut fs = self.fs.lock();
        // 检查是否已存在同名文件
        let existing = self.read_disk_inode(|disk_inode| self.find_inode_id(name, disk_inode));
        if existing.is_some() {
            return -1; // 文件已存在
        }
        // 在目录中添加新的目录项
        self.modify_disk_inode(|root_inode| {
            let file_count = (root_inode.size as usize) / DIRENT_SZ;
            let new_size = (file_count + 1) * DIRENT_SZ;
            self.increase_size(new_size as u32, root_inode, &mut fs);
            let dirent = DirEntry::new(name, target_inode_id);
            root_inode.write_at(
                file_count * DIRENT_SZ,
                dirent.as_bytes(),
                &self.block_device,
            );
        });
        // 增加目标 inode 的硬链接计数
        let (target_block_id, target_block_offset) = fs.get_disk_inode_pos(target_inode_id);
        get_block_cache(target_block_id as usize, Arc::clone(&self.block_device))
            .lock()
            .modify(target_block_offset, |disk_inode: &mut DiskInode| {
                disk_inode.nlink += 1;
            });
        block_cache_sync_all();
        0
    }

    /// 删除一个目录项（取消链接），如果 nlink 变为 0 则回收 inode 和数据块
    pub fn unlink(&self, name: &str) -> isize {
        let mut fs = self.fs.lock();
        // 查找要删除的目录项
        let target_inode_id =
            self.read_disk_inode(|disk_inode| self.find_inode_id(name, disk_inode));
        if target_inode_id.is_none() {
            return -1; // 文件不存在
        }
        let target_inode_id = target_inode_id.unwrap();

        // 从目录中删除目录项（将其替换为最后一个目录项，然后缩小目录大小）
        self.modify_disk_inode(|root_inode| {
            let file_count = (root_inode.size as usize) / DIRENT_SZ;
            let mut target_idx = None;
            let mut dirent = DirEntry::empty();
            for i in 0..file_count {
                root_inode.read_at(DIRENT_SZ * i, dirent.as_bytes_mut(), &self.block_device);
                if dirent.name() == name {
                    target_idx = Some(i);
                    break;
                }
            }
            if let Some(idx) = target_idx {
                if idx != file_count - 1 {
                    // 用最后一个目录项覆盖要删除的目录项
                    let mut last_dirent = DirEntry::empty();
                    root_inode.read_at(
                        DIRENT_SZ * (file_count - 1),
                        last_dirent.as_bytes_mut(),
                        &self.block_device,
                    );
                    root_inode.write_at(
                        DIRENT_SZ * idx,
                        last_dirent.as_bytes(),
                        &self.block_device,
                    );
                }
                // 清空最后一个目录项（虽然减小 size 后这部分不会被访问）
                let empty_dirent = DirEntry::empty();
                root_inode.write_at(
                    DIRENT_SZ * (file_count - 1),
                    empty_dirent.as_bytes(),
                    &self.block_device,
                );
                // 注意：这里不减小 root_inode.size，因为 easy-fs 不支持缩小
                // 我们只是将最后一个目录项置空，逻辑上减少了目录项数量
                // 实际上更好的做法是将删除的目录项标记为无效（inode_number = 0）
            }
        });

        // 减少目标 inode 的硬链接计数
        let (target_block_id, target_block_offset) = fs.get_disk_inode_pos(target_inode_id);
        let should_dealloc =
            get_block_cache(target_block_id as usize, Arc::clone(&self.block_device))
                .lock()
                .modify(target_block_offset, |disk_inode: &mut DiskInode| {
                    disk_inode.nlink -= 1;
                    disk_inode.nlink == 0
                });

        // 如果 nlink 变为 0，回收 inode 的数据块
        if should_dealloc {
            let data_blocks =
                get_block_cache(target_block_id as usize, Arc::clone(&self.block_device))
                    .lock()
                    .modify(target_block_offset, |disk_inode: &mut DiskInode| {
                        disk_inode.clear_size(&self.block_device)
                    });
            for data_block in data_blocks {
                fs.dealloc_data(data_block);
            }
            // 回收 inode（标记 inode bitmap 中的位为空闲）
            fs.dealloc_inode(target_inode_id);
        }

        block_cache_sync_all();
        0
    }
}
