/*
 * Created by Mayur Pawashe on 8/9/13.
 *
 * Copyright (c) 2013 zgcoder
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

#import "ZGDocumentWindowController.h"
#import "ZGDocumentTableController.h"
#import "ZGDocumentSearchController.h"
#import "ZGDocumentBreakPointController.h"
#import "ZGVariableController.h"
#import "ZGEditValueWindowController.h"
#import "ZGEditAddressWindowController.h"
#import "ZGEditSizeWindowController.h"
#import "ZGScriptManager.h"
#import "ZGProcessList.h"
#import "ZGProcess.h"
#import "ZGVariableTypes.h"
#import "ZGAppController.h"
#import "ZGRunningProcess.h"
#import "ZGPreferencesController.h"
#import "ZGDocumentData.h"
#import "ZGSearchData.h"
#import "ZGSearchProgress.h"
#import "ZGSearchResults.h"
#import "ZGAppController.h"
#import "ZGDebuggerController.h"
#import "ZGMemoryViewerController.h"
#import "ZGDocument.h"
#import "ZGVirtualMemory.h"
#import "ZGVirtualMemoryHelpers.h"
#import "APTokenSearchField.h"
#import "ZGSearchToken.h"
#import "ZGDocumentOptionsViewController.h"

#define ZGProtectionGroup @"ZGProtectionGroup"
#define ZGProtectionItemAll @"ZGProtectionAll"
#define ZGProtectionItemWrite @"ZGProtectionWrite"
#define ZGProtectionItemExecute @"ZGProtectionExecute"

#define ZGQualifierGroup @"ZGQualifierGroup"
#define ZGQualifierSigned @"ZGQualifierSigned"
#define ZGQualifierUnsigned @"ZGQualifierUnsigned"

#define ZGStringMatchingGroup @"ZGStringMatchingGroup"
#define ZGStringIgnoreCase @"ZGStringIgnoreCase"
#define ZGStringNullTerminated @"ZGStringNullTerminated"

@interface ZGDocumentWindowController ()

@property (nonatomic) ZGEditValueWindowController *editValueWindowController;
@property (nonatomic) ZGEditAddressWindowController *editAddressWindowController;
@property (nonatomic) ZGEditSizeWindowController *editSizeWindowController;

@property (nonatomic) AGScopeBarGroup *protectionGroup;
@property (nonatomic) AGScopeBarGroup *qualifierGroup;
@property (nonatomic) AGScopeBarGroup *stringMatchingGroup;

@property (assign) IBOutlet NSTextField *generalStatusTextField;

@property (nonatomic) NSPopover *advancedOptionsPopover;

@end

@implementation ZGDocumentWindowController

- (id)init
{
	self = [super initWithWindowNibName:@"MyDocument"];
	if (self != nil)
	{
		[[ZGProcessList sharedProcessList]
		 addObserver:self
		 forKeyPath:@"runningProcesses"
		 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
		 context:NULL];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	
	[[ZGProcessList sharedProcessList]
	 removeObserver:self
	 forKeyPath:@"runningProcesses"];
	
	[self.searchController cleanUp];
	[self.tableController cleanUp];
	[self.scriptManager cleanup];
}

- (void)setupScopeBar
{
	self.protectionGroup = [self.scopeBar addGroupWithIdentifier:ZGProtectionGroup label:@"Protection:" items:nil];
	[self.protectionGroup addItemWithIdentifier:ZGProtectionItemAll title:@"All"];
	[self.protectionGroup addItemWithIdentifier:ZGProtectionItemWrite title:@"Write"];
	[self.protectionGroup addItemWithIdentifier:ZGProtectionItemExecute title:@"Execute"];
	self.protectionGroup.selectionMode = AGScopeBarGroupSelectOne;
	
	self.qualifierGroup = [[AGScopeBarGroup alloc] initWithIdentifier:ZGQualifierGroup];
	self.qualifierGroup.label = @"Qualifier:";
	[self.qualifierGroup addItemWithIdentifier:ZGQualifierSigned title:@"Signed"];
	[self.qualifierGroup addItemWithIdentifier:ZGQualifierUnsigned title:@"Unsigned"];
	self.qualifierGroup.selectionMode = AGScopeBarGroupSelectOne;
	
	self.stringMatchingGroup = [[AGScopeBarGroup alloc] initWithIdentifier:ZGStringMatchingGroup];
	self.stringMatchingGroup.label = @"Matching:";
	[self.stringMatchingGroup addItemWithIdentifier:ZGStringIgnoreCase title:@"Ignore Case"];
	[self.stringMatchingGroup addItemWithIdentifier:ZGStringNullTerminated title:@"Null Terminated"];
	self.stringMatchingGroup.selectionMode = AGScopeBarGroupSelectAny;
	
	// Set delegate after setting up scope bar so we won't receive initial selection events beforehand
	self.scopeBar.delegate = self;
}

- (void)scopeBar:(AGScopeBar *)scopeBar item:(AGScopeBarItem *)item wasSelected:(BOOL)selected
{
	if ([item.group.identifier isEqualToString:ZGProtectionGroup])
	{
		if (selected)
		{
			if ([item.identifier isEqualToString:ZGProtectionItemAll])
			{
				self.searchData.protectionMode = ZGProtectionAll;
			}
			else if ([item.identifier isEqualToString:ZGProtectionItemWrite])
			{
				self.searchData.protectionMode = ZGProtectionWrite;
			}
			else if ([item.identifier isEqualToString:ZGProtectionItemExecute])
			{
				self.searchData.protectionMode = ZGProtectionExecute;
			}
			
			[self markDocumentChange];
		}
	}
	else if ([item.group.identifier isEqualToString:ZGQualifierGroup])
	{
		if (selected)
		{
			[self changeIntegerQualifier:[item.identifier isEqualToString:ZGQualifierSigned] ? ZGSigned : ZGUnsigned];
		}
	}
	else if ([item.group.identifier isEqualToString:ZGStringMatchingGroup])
	{
		if ([item.identifier isEqualToString:ZGStringIgnoreCase])
		{
			self.searchData.shouldIgnoreStringCase = selected;
		}
		else if ([item.identifier isEqualToString:ZGStringNullTerminated])
		{
			self.searchData.shouldIncludeNullTerminator = selected;
		}
		
		[self markDocumentChange];
	}
}

- (void)windowDidLoad
{
	[super windowDidLoad];
	
	self.documentData = [(ZGDocument *)self.document data];
	self.searchData = [self.document searchData];
	
	self.tableController = [[ZGDocumentTableController alloc] initWithWindowController:self];
	self.variableController = [[ZGVariableController alloc] initWithWindowController:self];
	self.searchController = [[ZGDocumentSearchController alloc] initWithWindowController:self];
	self.documentBreakPointController = [[ZGDocumentBreakPointController alloc] initWithWindowController:self];
	self.scriptManager = [[ZGScriptManager alloc] initWithWindowController:self];
	
	self.tableController.variablesTableView = self.variablesTableView;
	
	self.searchValueTextField.cell.sendsSearchStringImmediately = NO;
	self.searchValueTextField.cell.sendsSearchStringOnlyAfterReturn = YES;
	
	[self setupScopeBar];
	
	[self.storeValuesButton.image setTemplate:YES];
	[[NSImage imageNamed:@"container_filled"] setTemplate:YES];
	
	[self.generalStatusTextField.cell setBackgroundStyle:NSBackgroundStyleRaised];
	
	if ([self.window respondsToSelector:@selector(occlusionState)])
	{
		[[NSNotificationCenter defaultCenter]
		 addObserver:self
		 selector:@selector(windowDidChangeOcclusionState:)
		 name:NSWindowDidChangeOcclusionStateNotification
		 object:self.window];
	}
	
	[[NSNotificationCenter defaultCenter]
	 addObserver:self
	 selector:@selector(runningApplicationsPopUpButtonWillPopUp:)
	 name:NSPopUpButtonWillPopUpNotification
	 object:self.runningApplicationsPopUpButton];
	
	[self loadDocumentUserInterface];
}

- (void)updateObservingProcessOcclusionState
{
	if ([self.window respondsToSelector:@selector(occlusionState)])
	{
		BOOL shouldKeepWatchVariablesTimer = [self.tableController updateWatchVariablesTimer];
		if (self.isOccluded && !shouldKeepWatchVariablesTimer && !self.searchController.canCancelTask)
		{
			BOOL foundRunningScript = NO;
			for (ZGVariable *variable in self.documentData.variables)
			{
				if (variable.enabled && variable.type == ZGScript)
				{
					foundRunningScript = YES;
					break;
				}
			}
			
			if (!foundRunningScript)
			{
				if (self.currentProcess.valid)
				{
					[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
				}
				
				[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
			}
		}
		else if (!self.isOccluded)
		{
			if (self.currentProcess.valid)
			{
				[[ZGProcessList sharedProcessList] addPriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
			}
			else
			{
				[[ZGProcessList sharedProcessList] requestPollingWithObserver:self];
			}
		}
	}
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification
{
	self.isOccluded = (self.window.occlusionState & NSWindowOcclusionStateVisible) == 0;
	if (!self.isOccluded)
	{
		[[ZGProcessList sharedProcessList] retrieveList];
		[self.tableController.variablesTableView reloadData];
	}
	[self updateObservingProcessOcclusionState];
}

- (void)windowWillClose:(NSNotification *)notification
{
	if ([notification object] == self.window)
	{
		if (self.currentProcess.valid)
		{
			[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
		}
		
		[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
	}
}

- (void)setStatus:(id)status
{
	if (status == nil)
	{
		NSUInteger variableCount = self.documentData.variables.count + self.searchController.searchResults.addressCount;
		
		NSNumberFormatter *numberOfVariablesFormatter = [[NSNumberFormatter alloc] init];
		numberOfVariablesFormatter.format = @"#,###";
		
		NSString *valuesDisplayedString = [NSString stringWithFormat:@"Displaying %@ value", [numberOfVariablesFormatter stringFromNumber:@(variableCount)]];
		
		if (variableCount != 1)
		{
			valuesDisplayedString = [valuesDisplayedString stringByAppendingString:@"s"];
		}
		
		[self.generalStatusTextField setStringValue:valuesDisplayedString];
	}
	else if ([status isKindOfClass:[NSString class]])
	{
		[self.generalStatusTextField setStringValue:status];
	}
	else if ([status isKindOfClass:[NSAttributedString class]])
	{
		[self.generalStatusTextField setAttributedStringValue:status];
	}
}

- (void)loadDocumentUserInterface
{
	// don't use the last selected process name if the corresponding process isn't alive
	NSString *lastSelectedProcessName = [[ZGAppController sharedController] lastSelectedProcessName];
	if (!self.documentData.desiredProcessName && lastSelectedProcessName)
	{
		BOOL foundApplication =
		([NSWorkspace.sharedWorkspace.runningApplications
		  indexOfObjectPassingTest:^BOOL (id object, NSUInteger index, BOOL *stop)
		  {
			  return [[object localizedName] isEqualToString:lastSelectedProcessName];
		  }] != NSNotFound);
		
		if (foundApplication)
		{
			self.documentData.desiredProcessName = lastSelectedProcessName;
		}
	}
    
	[self setStatus:nil];
	
	[self addProcessesToPopupButton];
	
	[self.variableController disableHarmfulVariables:self.documentData.variables];
	[self updateVariables:self.documentData.variables searchResults:nil];
	
	switch (self.searchData.protectionMode)
	{
		case ZGProtectionAll:
			[self.protectionGroup setSelected:YES forItemWithIdentifier:ZGProtectionItemAll];
			break;
		case ZGProtectionWrite:
			[self.protectionGroup setSelected:YES forItemWithIdentifier:ZGProtectionItemWrite];
			break;
		case ZGProtectionExecute:
			[self.protectionGroup setSelected:YES forItemWithIdentifier:ZGProtectionItemExecute];
			break;
	}
	
	if (self.documentData.qualifierTag == ZGSigned)
	{
		[self.qualifierGroup setSelected:YES forItemWithIdentifier:ZGQualifierSigned];
	}
	else
	{
		[self.qualifierGroup setSelected:YES forItemWithIdentifier:ZGQualifierUnsigned];
	}
	
	if (self.searchData.shouldIgnoreStringCase)
	{
		[self.stringMatchingGroup setSelected:YES forItemWithIdentifier:ZGStringIgnoreCase];
	}
	
	if (self.searchData.shouldIncludeNullTerminator)
	{
		[self.stringMatchingGroup setSelected:YES forItemWithIdentifier:ZGStringNullTerminated];
	}
	
	if (self.advancedOptionsPopover != nil)
	{
		ZGDocumentOptionsViewController *optionsViewController = (id)self.advancedOptionsPopover.contentViewController;
		[optionsViewController reloadInterface];
	}
	
	self.searchValueTextField.objectValue = self.documentData.searchValue;
	
	[self.dataTypesPopUpButton selectItemWithTag:self.documentData.selectedDatatypeTag];
	[self selectDataTypeWithTag:(ZGVariableType)self.documentData.selectedDatatypeTag recordUndo:NO];
	
	[self.functionPopUpButton selectItemWithTag:self.documentData.functionTypeTag];
	[self functionTypePopUpButtonRequest:nil markChanges:NO];
}

#pragma mark Selected Variables

- (NSIndexSet *)selectedVariableIndexes
{
	NSIndexSet *tableIndexSet = self.tableController.variablesTableView.selectedRowIndexes;
	NSInteger clickedRow = self.tableController.variablesTableView.clickedRow;
	
	return (clickedRow != -1 && ![tableIndexSet containsIndex:clickedRow]) ? [NSIndexSet indexSetWithIndex:clickedRow] : tableIndexSet;
}

- (NSArray *)selectedVariables
{
	return [self.documentData.variables objectsAtIndexes:[self selectedVariableIndexes]];
}

#pragma mark Undo Manager

- (NSUndoManager *)windowWillReturnUndoManager:(id)sender
{
	return [self.document undoManager];
}

- (id)undoManager
{
	return [self.document undoManager];
}

- (void)markDocumentChange
{
	[self.document markChange];
}

#pragma mark Watching other applications

- (void)runningApplicationsPopUpButtonWillPopUp:(NSNotification *)notification
{
	[[ZGProcessList sharedProcessList] retrieveList];
}

- (IBAction)runningApplicationsPopUpButtonRequest:(id)sender
{
	BOOL pointerSizeChanged = YES;
	
	if (self.runningApplicationsPopUpButton.selectedItem.representedObject != self.currentProcess)
	{
		if (self.runningApplicationsPopUpButton.selectedItem.representedObject && self.currentProcess && [self.runningApplicationsPopUpButton.selectedItem.representedObject is64Bit] != self.currentProcess.is64Bit)
		{
			pointerSizeChanged = YES;
		}
		
		for (ZGVariable *variable in self.documentData.variables)
		{
			if (variable.enabled)
			{
				if (variable.type == ZGScript)
				{
					[self.scriptManager stopScriptForVariable:variable];
				}
				else if (variable.isFrozen)
				{
					variable.enabled = NO;
				}
			}
			
			variable.finishedEvaluatingDynamicAddress = NO;
		}
		
		// this is about as far as we go when it comes to undo/redos...
		[self.undoManager removeAllActions];
		
		[self.tableController clearCache];
	}
	
	if (self.currentProcess)
	{
		[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
	}
	
	self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
	
	if (pointerSizeChanged)
	{
		// Update the pointer variable sizes
		for (ZGVariable *variable in self.documentData.variables)
		{
			if (variable.type == ZGPointer)
			{
				variable.pointerSize = self.currentProcess.pointerSize;
			}
		}
		
		[self.tableController.variablesTableView reloadData];
	}
	
	// keep track of the process the user targeted
	[[ZGAppController sharedController] setLastSelectedProcessName:self.currentProcess.name];
	
	if (sender && ![self.documentData.desiredProcessName isEqualToString:self.currentProcess.name])
	{
		self.documentData.desiredProcessName = self.currentProcess.name;
		[self markDocumentChange];
	}
	else if (!self.documentData.desiredProcessName)
	{
		self.documentData.desiredProcessName = self.currentProcess.name;
	}
	
	if (self.currentProcess && self.currentProcess.valid)
	{
		[[ZGProcessList sharedProcessList] addPriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
		
		if (!self.currentProcess.hasGrantedAccess && ![self.currentProcess grantUsAccess])
		{
			NSAttributedString *errorMessage =
			[[NSAttributedString alloc]
			 initWithString:[NSString stringWithFormat:@"Failed accessing %@", self.currentProcess.name]
			 attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
			
			[self setStatus:errorMessage];
		}
		else
		{
			[self setStatus:nil];
			
			self.storeValuesButton.enabled = YES;
		}
	}
	
	[self.tableController updateWatchVariablesTimer];
	
	// Trash all other menu items if they're dead
	NSMutableArray *itemsToRemove = [[NSMutableArray alloc] init];
	for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.itemArray)
	{
		ZGRunningProcess *runningProcess = [[ZGRunningProcess alloc] init];
		runningProcess.processIdentifier = [[menuItem representedObject] processID];
		if (menuItem != self.runningApplicationsPopUpButton.selectedItem &&
			(![menuItem.representedObject valid] ||
			 ![[[ZGProcessList sharedProcessList] runningProcesses] containsObject:runningProcess]))
		{
			[itemsToRemove addObject:menuItem];
		}
	}
	
	for (id item in itemsToRemove)
	{
		[self.runningApplicationsPopUpButton removeItemAtIndex:[self.runningApplicationsPopUpButton indexOfItem:item]];
	}
}

- (void)addProcessesToPopupButton
{
	// Add running applications to popup button ; we want activiation policy for NSApplicationActivationPolicyRegular to appear first, since they're more likely to be targetted and more likely to have sufficient privillages for accessing virtual memory
	NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"activationPolicy" ascending:YES];
	for (ZGRunningProcess *runningProcess in [[[ZGProcessList sharedProcessList] runningProcesses] sortedArrayUsingDescriptors:@[sortDescriptor]])
	{
		[self addRunningProcessToPopupButton:runningProcess];
	}
	
	if (self.documentData.desiredProcessName && ![self.currentProcess.name isEqualToString:self.documentData.desiredProcessName])
	{
		ZGProcess *deadProcess =
		[[ZGProcess alloc]
		 initWithName:self.documentData.desiredProcessName
		 set64Bit:YES];
		
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (none)", deadProcess.name];
		menuItem.representedObject = deadProcess;
		
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		
		[self.runningApplicationsPopUpButton selectItem:menuItem];
		
		[self runningApplicationsPopUpButtonRequest:nil];
		[self removeRunningProcessFromPopupButton:nil];
	}
	else
	{
		[self runningApplicationsPopUpButtonRequest:nil];
	}
}

- (void)removeRunningProcessFromPopupButton:(ZGRunningProcess *)oldRunningProcess
{
	// Just to be sure
	if (oldRunningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
	{
		// oldRunningProcess == nil, means remove 'current process'
		if (self.currentProcess.processID == oldRunningProcess.processIdentifier || !oldRunningProcess)
		{
			// Don't remove the item, just indicate it's terminated
			[self setStatus:[NSString stringWithFormat:@"%@ is not running", self.currentProcess.name]];
			
			if (self.searchController.canCancelTask && !self.searchController.searchProgress.shouldCancelSearch)
			{
				[self.searchController cancelTask];
			}
			
			[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
			
			[self.tableController clearCache];
			for (ZGVariable *variable in self.documentData.variables)
			{
				variable.finishedEvaluatingDynamicAddress = NO;
				variable.value = NULL;
			}
			
			[self.currentProcess markInvalid];
			[self.tableController updateWatchVariablesTimer];
			[self.variablesTableView reloadData];
			
			self.storeValuesButton.enabled = NO;
			
			[[NSNotificationCenter defaultCenter]
			 postNotificationName:ZGTargetProcessDiedNotification
			 object:self.currentProcess];
			
			self.runningApplicationsPopUpButton.selectedItem.title = [NSString stringWithFormat:@"%@ (none)", self.currentProcess.name];
			
			// Set the icon to the standard one
			NSImage *regularAppIcon = [[NSImage imageNamed:@"NSDefaultApplicationIcon"] copy];
			if (regularAppIcon)
			{
				regularAppIcon.size = NSMakeSize(16, 16);
				self.runningApplicationsPopUpButton.selectedItem.image = regularAppIcon;
			}
			
			[[ZGProcessList sharedProcessList] requestPollingWithObserver:self];
		}
		else if (oldRunningProcess.processIdentifier != -1)
		{
			// Find the menu item, and remove it
			NSMenuItem *itemToRemove = nil;
			for (NSMenuItem *item in self.runningApplicationsPopUpButton.itemArray)
			{
				if ([item.representedObject processID] == oldRunningProcess.processIdentifier)
				{
					itemToRemove = item;
					break;
				}
			}
			
			if (itemToRemove)
			{
				[self.runningApplicationsPopUpButton removeItemAtIndex:[self.runningApplicationsPopUpButton indexOfItem:itemToRemove]];
			}
		}
	}
}

- (void)addRunningProcessToPopupButton:(ZGRunningProcess *)newRunningProcess
{
	// Don't add ourselves
	if (newRunningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
	{
		// Check if a dead application can be 'revived'
		for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.itemArray)
		{
			ZGProcess *process = menuItem.representedObject;
			if (process == self.currentProcess &&
				!self.currentProcess.valid &&
				[self.currentProcess.name isEqualToString:newRunningProcess.name])
			{
				self.currentProcess.processID = newRunningProcess.processIdentifier;
				
				self.currentProcess.is64Bit = newRunningProcess.is64Bit;
				menuItem.title = [NSString stringWithFormat:@"%@ (%d)", self.currentProcess.name, self.currentProcess.processID];
				
				NSImage *iconImage = [[newRunningProcess icon] copy];
				iconImage.size = NSMakeSize(16, 16);
				menuItem.image = iconImage;
				
				[self runningApplicationsPopUpButtonRequest:nil];
				
				[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
				
				return;
			}
		}
		
		// Otherwise add the new application
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (%d)", newRunningProcess.name, newRunningProcess.processIdentifier];
		
		NSImage *iconImage = [[newRunningProcess icon] copy];
		iconImage.size = NSMakeSize(16, 16);
		menuItem.image = iconImage;
		
		ZGProcess *representedProcess =
		[[ZGProcess alloc]
		 initWithName:newRunningProcess.name
		 processID:newRunningProcess.processIdentifier
		 set64Bit:newRunningProcess.is64Bit];
		
		menuItem.representedObject = representedProcess;
		
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		
		// If we found desired process name, select it
		if (![self.currentProcess.name isEqualToString:self.documentData.desiredProcessName] &&
			[self.documentData.desiredProcessName isEqualToString:newRunningProcess.name])
		{
			[self.runningApplicationsPopUpButton selectItem:menuItem];
			[self runningApplicationsPopUpButtonRequest:nil];
		}
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (self.document != nil && object == [ZGProcessList sharedProcessList] && self.runningApplicationsPopUpButton.itemArray.count > 0)
	{
		NSArray *newRunningProcesses = [change objectForKey:NSKeyValueChangeNewKey];
		NSArray *oldRunningProcesses = [change objectForKey:NSKeyValueChangeOldKey];
		
		if (newRunningProcesses)
		{
			for (ZGRunningProcess *runningProcess in newRunningProcesses)
			{
				[self addRunningProcessToPopupButton:runningProcess];
			}
		}
		
		if (oldRunningProcesses)
		{
			for (ZGRunningProcess *runningProcess in oldRunningProcesses)
			{
				[self removeRunningProcessFromPopupButton:runningProcess];
			}
		}
	}
}

- (BOOL)isClearable
{
	return (self.documentData.variables.count > 0 && [self.searchController canStartTask]);
}

- (void)changeIntegerQualifier:(ZGVariableQualifier)newQualifier
{
	ZGVariableQualifier oldQualifier = (ZGVariableQualifier)self.documentData.qualifierTag;
	if (oldQualifier != newQualifier)
	{
		for (ZGVariable *variable in self.documentData.variables)
		{
			switch (variable.type)
			{
				case ZGInt8:
				case ZGInt16:
				case ZGInt32:
				case ZGInt64:
					variable.qualifier = newQualifier;
					[variable updateStringValue];
					break;
				default:
					break;
			}
		}
		
		[self.tableController.variablesTableView reloadData];
		[self markDocumentChange];
		
		self.documentData.qualifierTag = newQualifier;
	}
}

- (void)updateFlagsRangeTextField
{
	ZGFunctionType functionType = (ZGFunctionType)self.functionPopUpButton.selectedItem.tag;
	
	if (functionType == ZGGreaterThan || functionType == ZGGreaterThanStored)
	{
		self.flagsLabel.stringValue = @"Below:";
		
		if (self.documentData.lastBelowRangeValue)
		{
			self.flagsTextField.stringValue = self.documentData.lastBelowRangeValue;
		}
		else
		{
			self.flagsTextField.stringValue = @"";
		}
	}
	else if (functionType == ZGLessThan || functionType == ZGLessThanStored)
	{
		self.flagsLabel.stringValue = @"Above:";
		
		if (self.documentData.lastAboveRangeValue)
		{
			self.flagsTextField.stringValue = self.documentData.lastAboveRangeValue;
		}
		else
		{
			self.flagsTextField.stringValue = @"";
		}
	}
}

- (void)changeScopeBarGroup:(AGScopeBarGroup *)group shouldExist:(BOOL)shouldExist
{
	BOOL alreadyExists = [self.scopeBar.groups containsObject:group];
	if (!shouldExist)
	{
		if (alreadyExists)
		{
			[self.scopeBar removeGroupAtIndex:[self.scopeBar.groups indexOfObject:group]];
		}
	}
	else
	{
		if (!alreadyExists)
		{
			[self.scopeBar insertGroup:group atIndex:1];
		}
	}
}

- (void)updateOptions
{
	ZGVariableType dataType = [self selectedDataType];
	ZGFunctionType functionType = [self selectedFunctionType];
	
	BOOL needsFlags = NO;
	BOOL needsQualifier = NO;
	BOOL needsStringMatching = NO;
	
	if (dataType == ZGFloat || dataType == ZGDouble)
	{
		if (functionType == ZGEquals || functionType == ZGNotEquals || functionType == ZGEqualsStored || functionType == ZGNotEqualsStored || functionType == ZGEqualsStoredLinear || functionType == ZGNotEqualsStoredLinear)
		{
			// epsilon
			self.flagsLabel.stringValue = @"Round Error:";
			if (self.documentData.lastEpsilonValue)
			{
				self.flagsTextField.stringValue = self.documentData.lastEpsilonValue;
			}
			else
			{
				self.flagsTextField.stringValue = @"";
			}
		}
		else
		{
			// range
			[self updateFlagsRangeTextField];
		}
		
		needsFlags = YES;
	}
	else if (dataType == ZGString8 || dataType == ZGString16)
	{
		needsStringMatching = YES;
	}
	else if (dataType != ZGByteArray)
	{
		if (functionType != ZGEquals && functionType != ZGNotEquals && functionType != ZGEqualsStored && functionType != ZGNotEqualsStored && functionType != ZGEqualsStoredLinear && functionType != ZGNotEqualsStoredLinear)
		{
			// range
			[self updateFlagsRangeTextField];
			
			needsFlags = YES;
		}
		
		if (dataType != ZGPointer)
		{
			needsQualifier = YES;
		}
	}
	
	[self changeScopeBarGroup:self.qualifierGroup shouldExist:needsQualifier];
	[self changeScopeBarGroup:self.stringMatchingGroup shouldExist:needsStringMatching];
	
	self.scopeBar.accessoryView = needsFlags ? self.scopeBarFlagsView : nil;
}

- (void)selectDataTypeWithTag:(ZGVariableType)newTag recordUndo:(BOOL)recordUndo
{
	ZGVariableType oldVariableTypeTag = (ZGVariableType)self.documentData.selectedDatatypeTag;
	
	self.documentData.selectedDatatypeTag = newTag;
	[self.dataTypesPopUpButton selectItemWithTag:newTag];
	
	self.functionPopUpButton.enabled = YES;
	
	[self updateOptions];
	
	if (recordUndo && oldVariableTypeTag != newTag)
	{
		[self.undoManager setActionName:@"Data Type Change"];
		[[self.undoManager prepareWithInvocationTarget:self]
		 selectDataTypeWithTag:oldVariableTypeTag
		 recordUndo:YES];
	}
}

- (IBAction)dataTypePopUpButtonRequest:(id)sender
{
	[self selectDataTypeWithTag:(ZGVariableType)[[sender selectedItem] tag] recordUndo:YES];
}

- (ZGVariableType)selectedDataType
{
	return (ZGVariableType)self.documentData.selectedDatatypeTag;
}

- (ZGFunctionType)selectedFunctionType
{
	self.documentData.searchValue = self.searchValueTextField.objectValue;
	
	BOOL isStoringValues = NO;
	for (id searchValueObject in self.documentData.searchValue)
	{
		if ([searchValueObject isKindOfClass:[ZGSearchToken class]])
		{
			isStoringValues = YES;
			break;
		}
	}
	
	ZGFunctionType functionType = (ZGFunctionType)self.documentData.functionTypeTag;
	if (isStoringValues)
	{
		BOOL isLinearlyExpressedStoredValue = self.documentData.searchValue.count > 1;
		switch (functionType)
		{
			case ZGEquals:
				if (!isLinearlyExpressedStoredValue)
				{
					functionType = ZGEqualsStored;
				}
				else
				{
					functionType = ZGEqualsStoredLinear;
				}
				break;
			case ZGNotEquals:
				if (!isLinearlyExpressedStoredValue)
				{
					functionType = ZGNotEqualsStored;
				}
				else
				{
					functionType = ZGNotEqualsStoredLinear;
				}
				break;
			case ZGGreaterThan:
				functionType = ZGGreaterThanStored;
				break;
			case ZGLessThan:
				functionType = ZGLessThanStored;
				break;
			default:
				break;
		}
	}
	
	return functionType;
}

- (BOOL)isFunctionTypeStore:(NSInteger)functionTypeTag
{
	BOOL isFunctionTypeStore;
	
	switch (functionTypeTag)
	{
		case ZGEqualsStored:
		case ZGNotEqualsStored:
		case ZGGreaterThanStored:
		case ZGLessThanStored:
		case ZGEqualsStoredLinear:
		case ZGNotEqualsStoredLinear:
			isFunctionTypeStore = YES;
			break;
		default:
			isFunctionTypeStore = NO;
	}
	
	return isFunctionTypeStore;
}

- (BOOL)isFunctionTypeStore
{
	return [self isFunctionTypeStore:[self selectedFunctionType]];
}

- (void)functionTypePopUpButtonRequest:(id)sender markChanges:(BOOL)shouldMarkChanges
{
	[self updateOptions];
	
	[self.window makeFirstResponder:self.searchValueTextField];
	
	if (shouldMarkChanges)
	{
		[self markDocumentChange];
	}
}

- (IBAction)functionTypePopUpButtonRequest:(id)sender
{
	self.documentData.functionTypeTag = [sender selectedTag];
	[self functionTypePopUpButtonRequest:sender markChanges:YES];
}

#pragma mark Useful Methods

- (void)updateVariables:(NSArray *)newWatchVariablesArray searchResults:(ZGSearchResults *)searchResults
{
	if (self.undoManager.isUndoing || self.undoManager.isRedoing)
	{
		[[self.undoManager prepareWithInvocationTarget:self] updateVariables:self.documentData.variables searchResults:self.searchController.searchResults];
	}
	
	self.documentData.variables = newWatchVariablesArray;
	self.searchController.searchResults = searchResults;
	
	[self.tableController updateWatchVariablesTimer];
	[self.tableController.variablesTableView reloadData];
	
	[self setStatus:nil];
}

#pragma mark Menu item validation

- (BOOL)validateUserInterfaceItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(clearSearchValues:))
	{
		if (!self.isClearable)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(storeAllValues:))
	{
		if (!self.currentProcess.valid || ![self.searchController canStartTask])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(insertStoredValueToken:))
	{
		if (self.searchData.savedData == nil)
		{
			return NO;
		}
		
		// I'd like to use self.documentData.searchValue but we don't update it instantly
		for (id object in self.searchValueTextField.objectValue)
		{
			if ([object isKindOfClass:[ZGSearchToken class]])
			{
				return NO;
			}
		}
	}
	
	else if (menuItem.action == @selector(removeSelectedSearchValues:))
	{
		if (self.selectedVariables.count == 0 || self.window.firstResponder != self.tableController.variablesTableView)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(freezeVariables:))
	{
		if (self.selectedVariables.count > 0)
		{
			// All the variables selected need to either be all unfrozen or all frozen
			BOOL isFrozen = [[self.selectedVariables objectAtIndex:0] isFrozen];
			BOOL isInconsistent = NO;
			
			for (ZGVariable *variable in [self.selectedVariables subarrayWithRange:NSMakeRange(1, self.selectedVariables.count-1)])
			{
				if (variable.isFrozen != isFrozen || !variable.value)
				{
					isInconsistent = YES;
					break;
				}
			}
			
			menuItem.title = [NSString stringWithFormat:@"%@ Variable%@", isFrozen ? @"Unfreeze" : @"Freeze", self.selectedVariables.count != 1 ? @"s" : @""];
			
			if (isInconsistent || !self.isClearable)
			{
				return NO;
			}
		}
		else
		{
			menuItem.title = @"Freeze Variables";
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(addVariable:))
	{
		if (![self.searchController canStartTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(undo:))
	{
		if ([self.searchController canCancelTask])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(copy:))
	{
		if (self.selectedVariables.count == 0)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(copyAddress:))
	{
		if (self.selectedVariables.count != 1)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(paste:))
	{
		if ([self.searchController canCancelTask] || ![NSPasteboard.generalPasteboard dataForType:ZGVariablePboardType])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(pauseOrUnpauseProcess:))
	{
		if (!self.currentProcess || !self.currentProcess.valid)
		{
			return NO;
		}
		
		integer_t suspendCount;
		if (!ZGSuspendCount(self.currentProcess.processTask, &suspendCount))
		{
			return NO;
		}
		else
		{
			menuItem.title = [NSString stringWithFormat:@"%@ Target", suspendCount > 0 ? @"Unpause" : @"Pause"];
		}
		
		if ([[[ZGAppController sharedController] debuggerController] isProcessIdentifierHalted:self.currentProcess.processID])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(requestEditingVariablesValue:))
	{
		menuItem.title = [NSString stringWithFormat:@"Edit Variable Value%@…", self.selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(requestEditingVariableAddress:))
	{
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
	}
    
    else if (menuItem.action == @selector(requestEditingVariablesSize:))
    {
		NSArray *selectedVariables = [self selectedVariables];
		menuItem.title = [NSString stringWithFormat:@"Edit Variable Size%@…", selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		// All selected variables must be Byte Array's
		for (ZGVariable *variable in selectedVariables)
		{
			if (variable.type != ZGByteArray)
			{
				return NO;
			}
		}
	}
	
	else if (menuItem.action == @selector(relativizeVariablesAddress:))
	{
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		NSArray *selectedVariables = [self selectedVariables];
		menuItem.title = [NSString stringWithFormat:@"Relativize Variable%@", selectedVariables.count != 1 ? @"s" : @""];
		
		for (ZGVariable *variable in selectedVariables)
		{
			ZGMemoryAddress relativeOffset = 0;
			ZGMemoryAddress slide = 0;
			if (variable.usesDynamicAddress || ZGSectionName(self.currentProcess.processTask, self.currentProcess.pointerSize, self.currentProcess.dylinkerBinary, variable.address, variable.size, NULL, &relativeOffset, &slide) == nil || (slide == 0 && variable.address - relativeOffset == self.currentProcess.baseAddress))
			{
				return NO;
			}
		}
	}
	
	else if (menuItem.action == @selector(functionTypePopUpButtonRequest:))
	{
		if ([self isFunctionTypeStore:menuItem.tag] && !self.searchController.searchData.savedData)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(watchVariable:))
	{
		if ([self.searchController canCancelTask] || !self.currentProcess.valid || self.selectedVariables.count != 1)
		{
			return NO;
		}
		
		ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
		
		ZGMemoryAddress memoryAddress = selectedVariable.address;
		ZGMemorySize memorySize = selectedVariable.size;
		ZGMemoryProtection memoryProtection;
		
		if (!ZGMemoryProtectionInRegion(self.currentProcess.processTask, &memoryAddress, &memorySize, &memoryProtection))
		{
			return NO;
		}
		
		if (memoryAddress + memorySize < selectedVariable.address || memoryAddress > selectedVariable.address + selectedVariable.size)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(nopVariables:))
	{
		menuItem.title = [NSString stringWithFormat:@"NOP Variable%@", self.selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		BOOL isValid = YES;
		for (ZGVariable *variable in self.selectedVariables)
		{
			if (variable.type != ZGByteArray || !variable.value)
			{
				isValid = NO;
				break;
			}
		}
		
		return isValid;
	}
	
	else if (menuItem.action == @selector(showMemoryViewer:) || menuItem.action == @selector(showDebugger:))
	{
		if (self.selectedVariables.count != 1 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
		
		ZGMemoryAddress memoryAddress = selectedVariable.address;
		ZGMemorySize memorySize = selectedVariable.size;
		ZGMemoryProtection memoryProtection;
		
		if (!ZGMemoryProtectionInRegion(self.currentProcess.processTask, &memoryAddress, &memorySize, &memoryProtection))
		{
			return NO;
		}
		
		if (memoryAddress > selectedVariable.address || memoryAddress + memorySize < selectedVariable.address + selectedVariable.size)
		{
			return NO;
		}
		
		if (!(memoryProtection & VM_PROT_READ))
		{
			return NO;
		}
	}
	
	return YES;
}

#pragma mark Search Field Tokens

- (void)deselectSearchField
{
	NSText *fieldEditor = [self.searchValueTextField currentEditor];
	if (fieldEditor != nil)
	{
		fieldEditor.selectedRange = NSMakeRange(fieldEditor.string.length, 0);
		[fieldEditor setNeedsDisplay:YES];
	}
}

- (IBAction)insertStoredValueToken:(id)sender
{
	self.searchValueTextField.objectValue = @[[[ZGSearchToken alloc] initWithName:@"Stored Value"]];
	[self deselectSearchField];
}

- (id)tokenField:(NSTokenField *)tokenField representedObjectForEditingString:(NSString *)editingString
{
	return editingString;
}

- (NSString *)tokenField:(NSTokenField *)tokenField displayStringForRepresentedObject:(id)representedObject
{
	NSString *result = nil;
	if ([representedObject isKindOfClass:[NSString class]])
	{
		result = representedObject;
	}
	else if ([representedObject isKindOfClass:[ZGSearchToken class]])
	{
		result = [representedObject name];
	}
	
	return result;
}

- (NSTokenStyle)tokenField:(NSTokenField *)tokenField styleForRepresentedObject:(id)representedObject
{
	return ([representedObject isKindOfClass:[ZGSearchToken class]]) ? NSRoundedTokenStyle : NSPlainTextTokenStyle;
}

- (NSString *)tokenField:(NSTokenField *)tokenField editingStringForRepresentedObject:(id)representedObject
{
	return ([representedObject isKindOfClass:[ZGSearchToken class]]) ? nil : representedObject;
}

#pragma mark Search Handling

- (IBAction)clearSearchValues:(id)sender
{
	[self.variableController clear];
}

- (IBAction)searchValue:(id)sender
{
	self.documentData.searchValue = self.searchValueTextField.objectValue;
	
	if (self.documentData.searchValue.count == 0 && self.searchController.canCancelTask)
	{
		[self.searchController cancelTask];
	}
	else if (self.documentData.searchValue.count == 0 && [self isClearable])
	{
		[self clearSearchValues:nil];
	}
	else if (self.documentData.searchValue.count > 0 && self.searchController.canStartTask && self.currentProcess.valid)
	{
		if (self.isFunctionTypeStore && self.searchData.savedData == nil)
		{
			NSRunAlertPanel(@"No Stored Values Available", @"There are no stored values to compare against. Please store values first before proceeding.", nil, nil, nil);
		}
		else
		{
			self.searchData.shouldCompareStoredValues = self.isFunctionTypeStore;
			[self markDocumentChange];
			
			[self.searchController search];
		}
	}
}

- (void)createSearchMenu
{
	NSMenu *searchMenu = [[NSMenu alloc] init];
	NSMenuItem *storedValuesMenuItem = [[NSMenuItem alloc] initWithTitle:@"Stored Value" action:@selector(insertStoredValueToken:) keyEquivalent:@""];
	[searchMenu addItem:storedValuesMenuItem];
	self.searchValueTextField.cell.searchMenu = searchMenu;
}

- (IBAction)storeAllValues:(id)sender
{
	self.documentData.searchValue = self.searchValueTextField.objectValue;
	[self.searchController storeAllValues];
}

- (IBAction)showAdvancedOptions:(id)sender
{
	if (self.advancedOptionsPopover == nil)
	{
		self.advancedOptionsPopover = [[NSPopover alloc] init];
		self.advancedOptionsPopover.contentViewController = [[ZGDocumentOptionsViewController alloc] initWithDocument:self.document];
		self.advancedOptionsPopover.behavior = NSPopoverBehaviorTransient;
	}
	
	[self.advancedOptionsPopover  showRelativeToRect:[sender bounds] ofView:sender preferredEdge:NSMaxYEdge];
}

#pragma mark Bindings

- (IBAction)ignoreDataAlignment:(id)sender
{
	self.documentData.ignoreDataAlignment = [sender state];
	[self markDocumentChange];
}

- (IBAction)changeBeginningAddressString:(id)sender
{
	self.documentData.beginningAddressStringValue = [sender stringValue];
	[self markDocumentChange];
}

- (IBAction)changeEndingAddressString:(id)sender
{
	self.documentData.endingAddressStringValue = [sender stringValue];
	[self markDocumentChange];
}

#pragma mark Variables Handling

- (IBAction)freezeVariables:(id)sender
{
	[self.variableController freezeVariables];
}

- (IBAction)copy:(id)sender
{
	[self.variableController copyVariables];
}

- (IBAction)copyAddress:(id)sender
{
	[self.variableController copyAddress];
}

- (IBAction)paste:(id)sender
{
	[self.variableController pasteVariables];
}

- (IBAction)cut:(id)sender
{
	[self.variableController copyVariables];
	[self removeSelectedSearchValues:nil];
}

- (IBAction)removeSelectedSearchValues:(id)sender
{
	[self.variableController removeSelectedSearchValues];
}

- (IBAction)addVariable:(id)sender
{
	[self.variableController addVariable:sender];
}

- (IBAction)nopVariables:(id)sender
{
	[self.variableController nopVariables:[self selectedVariables]];
}

- (IBAction)requestEditingVariablesValue:(id)sender
{
	if (self.editValueWindowController == nil)
	{
		self.editValueWindowController = [[ZGEditValueWindowController alloc] initWithVariableController:self.variableController];
	}
	
	[self.editValueWindowController requestEditingValuesFromVariables:self.selectedVariables withProcessTask:self.currentProcess.processTask attachedToWindow:self.window scriptManager:self.scriptManager];
}

- (IBAction)requestEditingVariableAddress:(id)sender
{
	if (self.editAddressWindowController == nil)
	{
		self.editAddressWindowController = [[ZGEditAddressWindowController alloc] initWithVariableController:self.variableController];
	}
	
	[self.editAddressWindowController requestEditingAddressFromVariable:[self.selectedVariables objectAtIndex:0] attachedToWindow:self.window];
}

- (IBAction)requestEditingVariablesSize:(id)sender
{
	if (self.editSizeWindowController == nil)
	{
		self.editSizeWindowController = [[ZGEditSizeWindowController alloc] initWithVariableController:self.variableController];
	}
	
	[self.editSizeWindowController requestEditingSizesFromVariables:self.selectedVariables attachedToWindow:self.window];
}

- (IBAction)relativizeVariablesAddress:(id)sender
{
	[self.variableController relativizeVariables:[self selectedVariables]];
}

#pragma mark Variable Watching Handling

- (IBAction)watchVariable:(id)sender
{
	[self.documentBreakPointController requestVariableWatch:(ZGWatchPointType)[sender tag]];
}

#pragma mark Showing Other Controllers

- (IBAction)showMemoryViewer:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] memoryViewer] jumpToMemoryAddress:selectedVariable.address withSelectionLength:selectedVariable.size > 0 ? selectedVariable.size : DEFAULT_MEMORY_VIEWER_SELECTION_LENGTH inProcess:self.currentProcess];
}

- (IBAction)showDebugger:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] debuggerController] showWindow:self];
	[[[ZGAppController sharedController] debuggerController] jumpToMemoryAddress:selectedVariable.address inProcess:self.currentProcess];
}

#pragma mark Pausing and Unpausing Processes

- (IBAction)pauseOrUnpauseProcess:(id)sender
{
	[ZGProcess pauseOrUnpauseProcessTask:self.currentProcess.processTask];
}

@end
