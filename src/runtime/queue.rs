use super::{Batch, Runnable, Task};
use std::{
    cell::UnsafeCell,
    marker::PhantomPinned,
    mem::MaybeUninit,
    pin::Pin,
    ptr::NonNull,
    sync::atomic::{spin_loop_hint, AtomicPtr, AtomicUsize, Ordering},
};

pub(crate) struct UnboundedQueue {
    head: AtomicUsize,
    tail: AtomicPtr<Task>,
    stub: Task,
    _pinned: PhantomPinned,
}

unsafe impl Send for UnboundedQueue {}
unsafe impl Sync for UnboundedQueue {}

impl UnboundedQueue {
    pub(crate) fn new() -> Self {
        Self {
            head: AtomicUsize::default(),
            tail: AtomicPtr::default(),
            stub: Task::from({
                static STUB: Runnable = Runnable(|_, _| {});
                &STUB
            }),
            _pinned: PhantomPinned,
        }
    }

    fn empty(self: Pin<&Self>) -> bool {
        let tail = NonNull::new(self.tail.load(Ordering::Relaxed));
        let stub = NonNull::from(&self.stub);
        tail.is_none() || tail == Some(stub)
    }

    pub(crate) fn push(self: Pin<&Self>, batch: impl Into<Batch>) {
        let batch: Batch = batch.into();
        let (batch_head, batch_tail) = match (batch.head, batch.tail) {
            (Some(head), Some(tail)) => (head, tail),
            _ => return,
        };

        let prev = self.tail.swap(batch_tail.as_ptr(), Ordering::AcqRel);
        let prev = NonNull::new(prev).unwrap_or(NonNull::from(&self.stub));

        let prev = unsafe { &*prev.as_ptr() };
        prev.next.store(batch_head.as_ptr(), Ordering::Release);
    }

    pub(crate) fn consumer(self: Pin<&Self>) -> Option<UnboundedConsumer<'_>> {
        let mut head = self.head.load(Ordering::Relaxed);
        loop {
            if (head & 1 != 0) || self.empty() {
                return None;
            }

            match self.head.compare_exchange_weak(
                head,
                head | 1,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(e) => head = e,
                Ok(_) => {
                    return Some(UnboundedConsumer {
                        queue: self,
                        head: NonNull::new((head & !1) as *mut Task)
                            .unwrap_or(NonNull::from(&self.stub)),
                    })
                }
            }
        }
    }
}

pub(crate) struct UnboundedConsumer<'a> {
    queue: Pin<&'a UnboundedQueue>,
    head: NonNull<Task>,
}

impl<'a> Drop for UnboundedConsumer<'a> {
    fn drop(&mut self) {
        let new_head = self.head.as_ptr() as usize;
        self.queue.head.store(new_head, Ordering::Release);
    }
}

impl<'a> Iterator for UnboundedConsumer<'a> {
    type Item = NonNull<Task>;

    fn next(&mut self) -> Option<Self::Item> {
        let stub = NonNull::from(&self.queue.stub);
        let mut head = self.head;
        let mut next = NonNull::new(unsafe { head.as_ref().next.load(Ordering::Acquire) });

        if head == stub {
            head = next?;
            self.head = head;
            next = NonNull::new(unsafe { head.as_ref().next.load(Ordering::Acquire) });
        }

        if let Some(new_head) = next {
            self.head = new_head;
            return Some(head);
        }

        let tail = self.queue.tail.load(Ordering::Relaxed);
        let tail = NonNull::new(tail).unwrap_or(stub);
        if head != tail {
            return None;
        }

        self.queue.push(unsafe {
            let stub = &mut *stub.as_ptr();
            Pin::new_unchecked(stub)
        });

        next = NonNull::new(unsafe { head.as_ref().next.load(Ordering::Acquire) });
        if let Some(new_head) = next {
            self.head = new_head;
            return Some(head);
        }

        None
    }
}

pub(crate) struct BoundedQueue {
    head: AtomicUsize,
    tail: UnsafeCell<AtomicUsize>,
    buffer: [AtomicPtr<Task>; Self::CAPACITY],
}

impl BoundedQueue {
    const CAPACITY: usize = 256;

    pub(crate) fn new() -> Self {
        Self {
            head: AtomicUsize::new(0),
            tail: UnsafeCell::new(AtomicUsize::new(0)),
            buffer: unsafe {
                let mut buffer = MaybeUninit::<[AtomicPtr<Task>; Self::CAPACITY]>::uninit();

                (0..Self::CAPACITY).for_each(|offset| {
                    let ptr = buffer.as_mut_ptr() as *mut AtomicPtr<Task>;
                    let slot = &mut *ptr.add(offset);
                    *slot.get_mut() = std::ptr::null_mut();
                });

                buffer.assume_init()
            },
        }
    }

    pub(crate) unsafe fn producer(&self) -> BoundedProducer<'_> {
        BoundedProducer {
            queue: self,
            tail: *(*self.tail.get()).get_mut(),
        }
    }
}

pub(crate) struct BoundedProducer<'a> {
    queue: &'a BoundedQueue,
    tail: usize,
}

impl<'a> BoundedProducer<'a> {
    pub(crate) fn push(&mut self, batch: impl Into<Batch>) -> Option<Batch> {
        let mut batch: Batch = batch.into();
        let mut head = self.queue.head.load(Ordering::Relaxed);

        loop {
            if batch.empty() {
                return None;
            }

            let size = self.tail.wrapping_sub(head);
            let remaining = BoundedQueue::CAPACITY - size;
            if remaining > 0 {
                (0..remaining).filter_map(|_| batch.pop()).for_each(|task| {
                    let index = self.tail % BoundedQueue::CAPACITY;
                    self.queue.buffer[index].store(task.as_ptr(), Ordering::Relaxed);
                    self.tail = self.tail.wrapping_add(1);
                });

                let tail_ref = unsafe { &*self.queue.tail.get() };
                tail_ref.store(self.tail, Ordering::Release);

                head = self.queue.head.load(Ordering::Relaxed);
                continue;
            }

            let migrate = BoundedQueue::CAPACITY / 2;
            if let Err(e) = self.queue.head.compare_exchange_weak(
                head,
                head.wrapping_add(migrate),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                head = e;
                continue;
            }

            let mut overflowed = (0..migrate).fold(Batch::new(), |mut batch, offset| {
                let index = head.wrapping_add(offset) % BoundedQueue::CAPACITY;
                let slot = &self.queue.buffer[index];
                let task = slot.load(Ordering::Relaxed);

                batch.push(unsafe {
                    let task = NonNull::new_unchecked(task);
                    let task = &mut *task.as_ptr();
                    Pin::new_unchecked(task)
                });

                batch
            });

            overflowed.push(batch);
            return Some(overflowed);
        }
    }

    pub(crate) fn pop(&mut self) -> Option<NonNull<Task>> {
        let mut head = self.queue.head.load(Ordering::Relaxed);
        loop {
            if self.tail == head {
                return None;
            }

            match self.queue.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(e) => head = e,
                Ok(_) => {
                    return NonNull::new({
                        let index = head % BoundedQueue::CAPACITY;
                        let slot = &self.queue.buffer[index];
                        slot.load(Ordering::Relaxed)
                    })
                }
            }
        }
    }

    pub(crate) fn pop_and_steal(&mut self, stealable: impl Stealable) -> Option<NonNull<Task>> {
        let head = self.queue.head.load(Ordering::Relaxed);
        if self.tail != head {
            return self.pop();
        }

        stealable.pop_and_steal(self)
    }
}

pub(crate) trait Stealable {
    fn pop_and_steal(self, producer: &mut BoundedProducer<'_>) -> Option<NonNull<Task>>;
}

impl<'a> Stealable for Pin<&'a UnboundedQueue> {
    fn pop_and_steal(self, producer: &mut BoundedProducer<'_>) -> Option<NonNull<Task>> {
        let mut consumer = self.consumer()?;
        let first_task = consumer.next()?;

        let head = producer.queue.head.load(Ordering::Relaxed);
        let size = producer.tail.wrapping_sub(head);
        let remaining = BoundedQueue::CAPACITY - size;

        let new_tail =
            (0..remaining)
                .filter_map(|_| consumer.next())
                .fold(producer.tail, |tail, task| {
                    let index = tail % BoundedQueue::CAPACITY;
                    let slot = &producer.queue.buffer[index];
                    slot.store(task.as_ptr(), Ordering::Relaxed);
                    tail.wrapping_add(1)
                });

        if new_tail != producer.tail {
            producer.tail = new_tail;
            let tail_ref = unsafe { &*producer.queue.tail.get() };
            tail_ref.store(new_tail, Ordering::Release);
        }

        Some(first_task)
    }
}

impl<'a> Stealable for &'a BoundedQueue {
    fn pop_and_steal(self, producer: &mut BoundedProducer<'_>) -> Option<NonNull<Task>> {
        debug_assert_eq!(producer.queue.head.load(Ordering::Relaxed), producer.tail,);

        let mut head = self.head.load(Ordering::Acquire);
        loop {
            let tail = {
                let tail_ref = unsafe { &*self.tail.get() };
                tail_ref.load(Ordering::Acquire)
            };

            let size = tail.wrapping_sub(head);
            if size == 0 {
                return None;
            }

            let steal = size - (size / 2);
            if steal > (BoundedQueue::CAPACITY / 2) {
                spin_loop_hint();
                head = self.head.load(Ordering::Acquire);
                continue;
            }

            let mut new_head = head;
            let mut consumer = (0..steal).map(|_| {
                let index = new_head % BoundedQueue::CAPACITY;
                let slot = &self.buffer[index];
                let task = slot.load(Ordering::Relaxed);
                new_head = new_head.wrapping_add(1);
                unsafe { NonNull::new_unchecked(task) }
            });

            let first_task = consumer.next();
            let new_producer_tail = consumer.fold(producer.tail, |tail, task| {
                let index = tail % BoundedQueue::CAPACITY;
                let slot = &producer.queue.buffer[index];
                slot.store(task.as_ptr(), Ordering::Relaxed);
                tail.wrapping_add(1)
            });

            if let Err(e) =
                self.head
                    .compare_exchange_weak(head, new_head, Ordering::AcqRel, Ordering::Acquire)
            {
                head = e;
                continue;
            }

            if new_producer_tail != producer.tail {
                producer.tail = new_producer_tail;
                let tail_ref = unsafe { &*producer.queue.tail.get() };
                tail_ref.store(new_producer_tail, Ordering::Release);
            }

            return first_task;
        }
    }
}
