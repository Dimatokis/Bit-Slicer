/*
 * Created by Mayur Pawashe on 12/27/12.
 *
 * Copyright (c) 2012 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ZGDissemblerController.h"
#import "ZGAppController.h"
#import "ZGProcess.h"
#import "ZGCalculator.h"
#import "ZGUtilities.h"
#import "ZGProcessList.h"
#import "ZGRunningProcess.h"
#import "ZGInstruction.h"
#import "udis86.h"

@interface ZGDissemblerController ()

@property (assign) IBOutlet NSPopUpButton *runningApplicationsPopUpButton;
@property (assign) IBOutlet NSTextField *addressTextField;
@property (assign) IBOutlet NSTableView *instructionsTableView;
@property (assign) IBOutlet NSProgressIndicator *dissemblyProgressIndicator;
@property (assign) IBOutlet NSButton *stopButton;

@property (readwrite) ZGMemoryAddress currentMemoryAddress;
@property (readwrite) ZGMemorySize currentMemorySize;

@property (nonatomic, strong) NSArray *instructions;

@property (readwrite, strong, nonatomic) NSTimer *updateInstructionsTimer;
@property (readwrite, nonatomic) BOOL dissembling;

@end

@implementation ZGDissemblerController

- (id)init
{
	self = [super initWithWindowNibName:NSStringFromClass([self class])];
	
	return self;
}

- (void)setCurrentProcess:(ZGProcess *)newProcess
{
	BOOL shouldUpdate = NO;
	
	if (_currentProcess.processID != newProcess.processID)
	{
		shouldUpdate = YES;
	}
	_currentProcess = newProcess;
	if (_currentProcess && ![_currentProcess hasGrantedAccess])
	{
		if (![_currentProcess grantUsAccess])
		{
			shouldUpdate = YES;
			//NSLog(@"Debugger failed to grant access to PID %d", _currentProcess.processID);
		}
	}
	
	if (shouldUpdate)
	{
		self.instructions = @[];
		[self.instructionsTableView reloadData];
	}
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    
	// Add processes to popup button,
	[self updateRunningProcesses:[[ZGAppController sharedController] lastSelectedProcessName]];
	
	[[ZGProcessList sharedProcessList]
	 addObserver:self
	 forKeyPath:@"runningProcesses"
	 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
	 context:NULL];
}

- (IBAction)showWindow:(id)sender
{
	[super showWindow:sender];
	
	if (!self.updateInstructionsTimer)
	{
		self.updateInstructionsTimer =
			[NSTimer
			 scheduledTimerWithTimeInterval:0.5
			 target:self
			 selector:@selector(updateInstructionsTimer:)
			 userInfo:nil
			 repeats:YES];
	}
}

- (void)windowWillClose:(NSNotification *)notification
{
	[self.updateInstructionsTimer invalidate];
	self.updateInstructionsTimer = nil;
}

- (void)updateInstructionsTimer:(NSTimer *)timer
{
	if (self.currentProcess.processID != NON_EXISTENT_PID_NUMBER && self.instructionsTableView.editedRow == -1)
	{
		NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
		if (visibleRowsRange.location + visibleRowsRange.length <= self.instructions.count)
		{
			[[self.instructions subarrayWithRange:visibleRowsRange] enumerateObjectsUsingBlock:^(ZGInstruction *instruction, NSUInteger index, BOOL *stop)
			 {
				 void *bytes = NULL;
				 ZGMemorySize size = instruction.variable.size;
				 if (ZGReadBytes(self.currentProcess.processTask, instruction.variable.address, &bytes, &size))
				 {
					 BOOL shouldUpdateText = (instruction.text == nil);
					 if (memcmp(bytes, instruction.variable.value, size) != 0)
					 {
						 instruction.variable.value = bytes;
						 [instruction.variable updateStringValue];
						 shouldUpdateText = YES;
					 }
					 
					 if (shouldUpdateText)
					 {
						 ud_t object;
						 ud_init(&object);
						 ud_set_input_buffer(&object, bytes, size);
						 ud_set_mode(&object, self.currentProcess.pointerSize * 8);
						 ud_set_syntax(&object, UD_SYN_INTEL);
						 
						 while (ud_disassemble(&object) > 0)
						 {
							 instruction.text = @(ud_insn_asm(&object));
						 }
						 
						 [self.instructionsTableView reloadData];
					 }
					 
					 ZGFreeBytes(self.currentProcess.processTask, bytes, size);
				 }
			 }];
		}
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (object == [ZGProcessList sharedProcessList])
	{
		[self updateRunningProcesses:nil];
	}
}

- (void)updateRunningProcesses:(NSString *)desiredProcessName
{
	[self.runningApplicationsPopUpButton removeAllItems];
	
	NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"activationPolicy" ascending:YES];
	for (ZGRunningProcess *runningProcess in  [[[ZGProcessList sharedProcessList] runningProcesses] sortedArrayUsingDescriptors:@[sortDescriptor]])
	{
		if (runningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
		{
			NSMenuItem *menuItem = [[NSMenuItem alloc] init];
			menuItem.title = [NSString stringWithFormat:@"%@ (%d)", runningProcess.name, runningProcess.processIdentifier];
			NSImage *iconImage = [runningProcess.icon copy];
			iconImage.size = NSMakeSize(16, 16);
			menuItem.image = iconImage;
			ZGProcess *representedProcess =
				[[ZGProcess alloc]
				 initWithName:runningProcess.name
				 processID:runningProcess.processIdentifier
				 set64Bit:runningProcess.is64Bit];
			
			menuItem.representedObject = representedProcess;
			
			[self.runningApplicationsPopUpButton.menu addItem:menuItem];
			
			// Revive process
			if (self.currentProcess.processID == NON_EXISTENT_PID_NUMBER && [self.currentProcess.name isEqualToString:runningProcess.name])
			{
				self.currentProcess.processID = runningProcess.processIdentifier;
			}
			
			if (self.currentProcess.processID == runningProcess.processIdentifier || [desiredProcessName isEqualToString:runningProcess.name])
			{
				[self.runningApplicationsPopUpButton selectItem:self.runningApplicationsPopUpButton.lastItem];
			}
		}
	}
	
	// Handle dead process
	if (self.currentProcess && self.currentProcess.processID != [self.runningApplicationsPopUpButton.selectedItem.representedObject processID])
	{
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (none)", self.currentProcess.name];
		NSImage *iconImage = [[NSImage imageNamed:@"NSDefaultApplicationIcon"] copy];
		iconImage.size = NSMakeSize(16, 16);
		menuItem.image = iconImage;
		menuItem.representedObject = self.currentProcess;
		self.currentProcess.processID = NON_EXISTENT_PID_NUMBER;
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		[self.runningApplicationsPopUpButton selectItem:self.runningApplicationsPopUpButton.lastItem];
	}
	
	self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
}

- (IBAction)runningApplicationsPopUpButton:(id)sender
{
	if ([self.runningApplicationsPopUpButton.selectedItem.representedObject processID] != self.currentProcess.processID)
	{
		self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
	}
}

- (void)selectAddress:(ZGMemoryAddress)address
{
	NSUInteger selectionIndex = 0;
	BOOL foundSelection = NO;
	
	for (ZGInstruction *instruction in self.instructions)
	{
		if (instruction.variable.address >= address)
		{
			foundSelection = YES;
			break;
		}
		selectionIndex++;
	}
	
	if (foundSelection)
	{
		[self.instructionsTableView scrollRowToVisible:selectionIndex];
		[self.instructionsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectionIndex] byExtendingSelection:NO];
		[self.window makeFirstResponder:self.instructionsTableView];
	}
}

- (ZGMemoryAddress)findInstructionAddressFromBreakPointAddress:(ZGMemoryAddress)breakPointAddress inProcess:(ZGProcess *)process
{
	ZGMemoryAddress instructionAddress = 0x0;
	
	for (ZGRegion *region in ZGRegionsForProcessTask(process.processTask))
	{
		if (breakPointAddress >= region.address && breakPointAddress < region.address + region.size)
		{
			// Start an arbitrary number of bytes before our break point address and decode the instructions
			// Eventually they will converge into correct offsets
			// So retrieve the offset to the last instruction while decoding
			// We do this instead of starting at region.address due to performance
			
			ZGMemoryAddress startAddress = breakPointAddress - 1024;
			if (startAddress < region.address)
			{
				startAddress = region.address;
			}
			ZGMemorySize size = breakPointAddress - startAddress;
			
			void *bytes = NULL;
			if (ZGReadBytes(process.processTask, startAddress, &bytes, &size))
			{
				ud_t object;
				ud_init(&object);
				ud_set_input_buffer(&object, bytes, size);
				ud_set_mode(&object, process.pointerSize * 8);
				ud_set_syntax(&object, UD_SYN_INTEL);
				
				ZGMemorySize memoryOffset = 0;
				while (ud_disassemble(&object) > 0)
				{
					if (memoryOffset + ud_insn_len(&object) < size)
					{
						memoryOffset += ud_insn_len(&object);
					}
				}
				
				instructionAddress = startAddress + memoryOffset;
				
				ZGFreeBytes(process.processTask, bytes, size);
			}
			
			break;
		}
	}
	
	return instructionAddress;
}

- (IBAction)stopDissembling:(id)sender
{
	self.dissembling = NO;
	[self.stopButton setEnabled:NO];
}

- (void)updateDissemblerWithAddress:(ZGMemoryAddress)address size:(ZGMemorySize)theSize selectionAddress:(ZGMemoryAddress)selectionAddress
{
	[self.dissemblyProgressIndicator setMinValue:0];
	[self.dissemblyProgressIndicator setMaxValue:theSize];
	[self.dissemblyProgressIndicator setDoubleValue:0];
	[self.dissemblyProgressIndicator setHidden:NO];
	[self.addressTextField setEnabled:NO];
	[self.runningApplicationsPopUpButton setEnabled:NO];
	[self.stopButton setEnabled:YES];
	[self.stopButton setHidden:NO];
	
	self.currentMemoryAddress = address;
	self.currentMemorySize = 0;
	
	self.dissembling = YES;
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		//NSLog(@"Trying to do of size %lld", theSize);
		void *bytes;
		ZGMemorySize size = theSize;
		if (ZGReadBytes(self.currentProcess.processTask, address, &bytes, &size))
		{
			ud_t object;
			ud_init(&object);
			ud_set_input_buffer(&object, bytes, size);
			ud_set_mode(&object, self.currentProcess.pointerSize * 8);
			ud_set_syntax(&object, UD_SYN_INTEL);
			
			__block NSMutableArray *newInstructions = [[NSMutableArray alloc] init];
			
			NSUInteger thresholdCount = 1000;
			NSUInteger totalInstructionCount = 0;
			__block NSUInteger selectionRow = 0;
			__block BOOL foundSelection = NO;
			
			void (^addBatchOfInstructions)(void) = ^{
				NSArray *currentBatch = newInstructions;
				
				dispatch_async(dispatch_get_main_queue(), ^{
					NSMutableArray *appendedInstructions = [[NSMutableArray alloc] initWithArray:self.instructions];
					[appendedInstructions addObjectsFromArray:currentBatch];
					
					if (self.instructions.count == 0)
					{
						[self.window makeFirstResponder:self.instructionsTableView];
					}
					self.instructions = [NSArray arrayWithArray:appendedInstructions];
					[self.instructionsTableView noteNumberOfRowsChanged];
					self.currentMemorySize = self.instructions.count;
					
					if (foundSelection)
					{
						[self.instructionsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectionRow] byExtendingSelection:NO];
						[self.instructionsTableView scrollRowToVisible:selectionRow];
						foundSelection = NO;
					}
				});
			};
			
			while (ud_disassemble(&object) > 0)
			{
				ZGInstruction *instruction = [[ZGInstruction alloc] init];
				instruction.variable = [[ZGVariable alloc] initWithValue:bytes + ud_insn_off(&object) size:ud_insn_len(&object) address:address + ud_insn_off(&object) type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize];
				
				[newInstructions addObject:instruction];
				
				dispatch_async(dispatch_get_main_queue(), ^{
					self.dissemblyProgressIndicator.doubleValue += instruction.variable.size;
					if (selectionAddress >= instruction.variable.address && selectionAddress < instruction.variable.address + instruction.variable.size)
					{
						selectionRow = totalInstructionCount;
						foundSelection = YES;
					}
				});
				
				if (!self.dissembling)
				{
					break;
				}
				
				totalInstructionCount++;
				
				if (totalInstructionCount >= thresholdCount)
				{
					addBatchOfInstructions();
					newInstructions = [[NSMutableArray alloc] init];
					thresholdCount *= 2;
				}
			}
			
			addBatchOfInstructions();
			
			dispatch_async(dispatch_get_main_queue(), ^{
				//NSLog(@"Done %ld, %ld", totalInstructionCount, self.instructions.count);
				self.dissembling = NO;
				[self.dissemblyProgressIndicator setHidden:YES];
				[self.addressTextField setEnabled:YES];
				[self.runningApplicationsPopUpButton setEnabled:YES];
				[self.stopButton setHidden:YES];
			});
			
			ZGFreeBytes(self.currentProcess.processTask, bytes, size);
		}
	});
}

- (IBAction)readMemory:(id)sender
{
	BOOL success = NO;
	
	if (![self.currentProcess hasGrantedAccess])
	{
		goto END_DEBUGGER_CHANGE;
	}
	
	// create scope block to allow for goto
	{
		NSString *calculatedMemoryAddressExpression = [ZGCalculator evaluateExpression:self.addressTextField.stringValue];
		
		ZGMemoryAddress calculatedMemoryAddress = 0;
		
		if (isValidNumber(calculatedMemoryAddressExpression))
		{
			calculatedMemoryAddress = memoryAddressFromExpression(calculatedMemoryAddressExpression);
		}
		
		NSArray *memoryRegions = ZGRegionsForProcessTask(self.currentProcess.processTask);
		if (memoryRegions.count == 0)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		ZGRegion *chosenRegion = nil;
		for (ZGRegion *region in memoryRegions)
		{
			if ((region.protection & VM_PROT_READ && region.protection & VM_PROT_EXECUTE) && (calculatedMemoryAddress <= 0 || (calculatedMemoryAddress >= region.address && calculatedMemoryAddress < region.address + region.size)))
			{
				chosenRegion = region;
				break;
			}
		}
		
		if (!chosenRegion)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		if (calculatedMemoryAddress <= 0)
		{
			calculatedMemoryAddress = chosenRegion.address;
			[self.addressTextField setStringValue:[NSString stringWithFormat:@"0x%llX", calculatedMemoryAddress]];
		}
		
		if (self.instructions.count > 0 && calculatedMemoryAddress >= self.currentMemoryAddress && calculatedMemoryAddress < self.currentMemoryAddress + self.currentMemorySize)
		{
			[self selectAddress:calculatedMemoryAddress];
			success = YES;
			goto END_DEBUGGER_CHANGE;
		}
		
		[self updateDissemblerWithAddress:chosenRegion.address size:chosenRegion.size selectionAddress:calculatedMemoryAddress];
		
		success = YES;
	}
	
END_DEBUGGER_CHANGE:
	if (!success)
	{
		// clear data
		self.instructions = [NSArray array];
		[self.instructionsTableView reloadData];
	}
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return self.instructions.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	id result = nil;
	if (rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		ZGInstruction *instruction = [self.instructions objectAtIndex:rowIndex];
		if ([tableColumn.identifier isEqualToString:@"address"])
		{
			result = instruction.variable.addressStringValue;
		}
		else if ([tableColumn.identifier isEqualToString:@"instruction"])
		{
			result = instruction.text;
		}
		else if ([tableColumn.identifier isEqualToString:@"bytes"])
		{
			result = instruction.variable.stringValue;
		}
	}
	
	return result;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
}

@end
