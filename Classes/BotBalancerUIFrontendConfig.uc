class BotBalancerUIFrontendConfig extends UTUIFrontEnd;

// Constants
// -----------------

Const SkinPath = "UI_Skin_Derived.UTDerivedSkin";

//**********************************************************************************
// Structs
//**********************************************************************************

struct SUIIdStringCollectionInfo
{
	var name Option;
	var array<int> Ids;
	var array<string> Names;
};

//**********************************************************************************
// Variables
//**********************************************************************************

var() transient localized string Title;

//'''''''''''''''''''''''''
// Workflow variables
//'''''''''''''''''''''''''

var transient bool bPendingClose;
var transient bool bRegeneratingOptions;	// Used to detect when the options are being regenerated

var transient array<SUIIdStringCollectionInfo> CollectionsIdStr;
var transient UTUIDataStore_2DStringList StringDatastore;
var() transient class<UTUIDataStore_2DStringList> StringDatastoreClass;
var transient array<name> RegisteredDatafields;
var() transient string DataFieldPrefix;

var() transient class<Settings> SettingsClass;
var() transient class<Object> ConfigClass;

//'''''''''''''''''''''''''
// UI element variables
//'''''''''''''''''''''''''

/** Reference to the messagebox scene. */
var transient UTUIScene_MessageBox MessageBoxReference;

var transient UISkin OriginalSkin;

//**********************************************************************************
// Inherited funtions
//**********************************************************************************

/** Post initialize callback */
event PostInitialize()
{
	`Log(name$"::PostInitialize",,'BotBalancer');

	//AdjustSkin();
	super.PostInitialize();

	SetupMenuOptions();
}

/** Scene activated event, sets up the title for the scene. */
event SceneActivated(bool bInitialActivation)
{
	Super.SceneActivated(bInitialActivation);

	FocusList();
}

/** Called just after this scene is removed from the active scenes array */
event SceneDeactivated()
{
	local int i;

	// revert skin before we set the pending close flag otherwise it doesn't get reverted
	//RevertSkin();
	bPendingClose = true;

	if (StringDatastore != none)
	{
		for (i=0; i<RegisteredDatafields.Length; i++)
		{
			StringDatastore.RemoveField(RegisteredDatafields[i]);
		}
		StringDatastore = none;
	}

	super.SceneDeactivated();
}

event NotifyGameSessionEnded()
{
	`Log(name$"::NotifyGameSessionEnded",,'BotBalancer');

	bPendingClose = true;

	// clear references
	OriginalSkin = none;

	super.NotifyGameSessionEnded();
}

/** Sets the title for this scene. */
function SetTitle()
{
	//local string FinalStr;
	local UILabel TitleLabel;

	`Log(name$"::SetTitle",,'BotBalancer');

	TitleLabel = GetTitleLabel();
	if ( TitleLabel != None )
	{
		if(TabControl == None)
		{
			//FinalStr = Caps(Localize("Titles", string(SceneTag), string(GetPackageName())));
			TitleLabel.SetDataStoreBinding(Title);
		}
		else
		{
			TitleLabel.SetDataStoreBinding("");
		}
	}
}

function SetupButtonBar()
{
	`Log(name$"::SetupButtonBar",,'BotBalancer');

	if (ButtonBar != none)
	{
		ButtonBar.Clear();
		ButtonBar.AppendButton("<Strings:UTGameUI.ButtonCallouts.Back>", OnButtonBar_Back);
		ButtonBar.AppendButton("<Strings:UTGameUI.ButtonCallouts.Accept>", OnButtonBar_Accept);
		ButtonBar.AppendButton("<Strings:UTGameUI.ButtonCallouts.ResetToDefaults>", OnButtonBar_ResetToDefaults);
	}
}

/**
 * Provides a hook for unrealscript to respond to input using actual input key names (i.e. Left, Tab, etc.)
 *
 * Called when an input key event is received which this widget responds to and is in the correct state to process.  The
 * keys and states widgets receive input for is managed through the UI editor's key binding dialog (F8).
 *
 * This delegate is called BEFORE kismet is given a chance to process the input.
 *
 * @param	EventParms	information about the input event.
 *
 * @return	TRUE to indicate that this input key was processed; no further processing will occur on this input key event.
 */
function bool HandleInputKey( const out InputEventParameters EventParms )
{
	local bool bResult;

	`Log(name$"::HandleInputKey",,'BotBalancer');

	if(EventParms.EventType==IE_Released)
	{
		if(EventParms.InputKeyName=='XboxTypeS_B' || EventParms.InputKeyName=='Escape')
		{
			OnBack();
			bResult=true;
		}
		else if(EventParms.InputKeyName=='XboxTypeS_LeftTrigger')
		{
			OnResetToDefaults();
			bResult=true;
		}
	}

	return bResult;
}

//**********************************************************************************
// Init funtions
//**********************************************************************************

// Initializes the menu option templates, and regenerates the option list
function SetupMenuOptions()
{
}

// Setup the data source bindings (but not the values)
function SetupOptionBindings()
{
}

function bool PopulateMenuOption(name PropertyName, out DynamicMenuOption menuopt)
{
	return ret;
}

function bool PopulateMenuObject(GeneratedObjectInfo OI)
{
	return false;
}

//**********************************************************************************
// UI callbacks
//**********************************************************************************

/** Button bar callbacks */
function bool OnButtonBar_Accept(UIScreenObject InButton, int PlayerIndex)
{
	`Log(name$"::OnButtonBar_Accept - InButton:"@InButton$" - PlayerIndex:"@PlayerIndex,,'BotBalancer');

	OnAccept();
	CloseScene(Self);

	return true;
}

function bool OnButtonBar_Back(UIScreenObject InButton, int PlayerIndex)
{
	`Log(name$"::OnButtonBar_Back - InButton:"@InButton$" - PlayerIndex:"@PlayerIndex,,'BotBalancer');
	OnBack();

	return true;
}

/** Buttonbar Callback. */
function bool OnButtonBar_ResetToDefaults(UIScreenObject InButton, int InPlayerIndex)
{
	`Log(name$"::OnButtonBar_ResetToDefaults - InButton:"@InButton$" - InPlayerIndex:"@InPlayerIndex,,'BotBalancer');
	OnResetToDefaults();

	return true;
}

/**
 * Callback for the reset to defaults confirmation dialog box.
 *
 * @param SelectionIdx	Selected item
 * @param PlayerIndex	Index of player that performed the action.
 */
function OnResetToDefaults_Confirm(UTUIScene_MessageBox MessageBox, int SelectionIdx, int PlayerIndex)
{
	`Log(name$"::OnResetToDefaults_Confirm - MessageBox:"@MessageBox$" - SelectionIdx:"@SelectionIdx$" - PlayerIndex:"@PlayerIndex,,'BotBalancer');

	if(SelectionIdx==0)
	{
		ResetToDefaults();
		CloseScene(self);
	}
}

//**********************************************************************************
// Button functions
//**********************************************************************************

function OnBack()
{
	`Log(name$"::OnBack",,'BotBalancer');
	CloseScene(self);
}

function OnAccept()
{
	local Settings SettingsObj;

	`Log(name$"::OnAccept",,'BotBalancer');

	SettingsObj = new SettingsClass;
	SettingsObj.SetSpecialValue('WebAdmin_Init', "");

	`Log(name$"::OnAccept - Save config",,'BotBalancer');
	SettingsObj.SetSpecialValue('WebAdmin_Save', "");
}

/** Reset to defaults callback. */
function OnResetToDefaults()
{
	local array<string> MessageBoxOptions;

	`Log(name$"::OnResetToDefaults",,'BotBalancer');

	MessageBoxReference = GetMessageBoxScene();

	if(MessageBoxReference != none)
	{
		MessageBoxOptions.AddItem("<Strings:UTGameUI.ButtonCallouts.ResetToDefaultAccept>");
		MessageBoxOptions.AddItem("<Strings:UTGameUI.ButtonCallouts.Cancel>");

		MessageBoxReference.SetPotentialOptions(MessageBoxOptions);
		MessageBoxReference.Display("<Strings:UTGameUI.MessageBox.ResetToDefaults_Message>", "<Strings:UTGameUI.MessageBox.ResetToDefaults_Title>", OnResetToDefaults_Confirm, 1);
	}
}

//**********************************************************************************
// UI functions
//**********************************************************************************

//function AdjustSkin()
//{
//	local UISkin Skin;

	//if (bPendingClose)
	//	return;

//	// make sure we're using the right skin
//	Skin = UISkin(DynamicLoadObject(SkinPath,class'UISkin'));
//	if ( Skin != none )
//	{
		//if (OriginalSkin == none)
		//{
		//	OriginalSkin = SceneClient.ActiveSkin;
		//}
//		SceneClient.ChangeActiveSkin(Skin);
//	}
//}

//function RevertSkin()
//{
//	if (bPendingClose)
//		return;

//	if (OriginalSkin != none)
//	{
//		SceneClient.ChangeActiveSkin(OriginalSkin);
//		OriginalSkin = none;
//	}
//}

function FocusList(optional int index = INDEX_NONE)
{
}

function string GetDescriptionOfSetting(name PropertyName, optional Settings Setts)
{
	local string ret;
	local string str;

	ret = Localize(SettingsClass.name$" Tooltips", string(PropertyName), string(class.GetPackageName()));
	if (Len(ret) == 0 || Left(ret, 1) == "?")
	{
		ret = "";

		if (Setts == none)
		{
			Setts = new SettingsClass;
		}

		if (Setts != none)
		{
			str = "PropertyDescription"$"_"$PropertyName;
			ret = Setts.GetSpecialValue(name(str));
		}
	}

	return ret;
}

function bool GetSettingsProperties(name PropertyName, out SettingsProperty out_Property, out SettingsPropertyPropertyMetaData out_PropertyMapping)
{
	local int index;
	index = SettingsClass.default.PropertyMappings.Find('Name', PropertyName);
	if (index != INDEX_NONE)
	{
		out_PropertyMapping = SettingsClass.default.PropertyMappings[index];
		if (index < SettingsClass.default.Properties.Length)
		{
			out_Property = SettingsClass.default.Properties[index];
			return true;
		}
	}

	return false;
}

function bool GetSettingsCollection(name PropertyName, out array<int> out_ids, out array<string> out_names)
{
	local SettingsProperty prop;
	local SettingsPropertyPropertyMetaData prop_mapping;
	local int i;
	local string str;

	if (GetSettingsProperties(PropertyName, prop, prop_mapping))
	{
		out_ids.Length = 0;
		out_names.Length = 0;
		for (i=0; i<prop_mapping.ValueMappings.Length; i++)
		{
			out_ids.AddItem(prop_mapping.ValueMappings[i].Id);

			str = string(prop_mapping.ValueMappings[i].Name);
			out_names.AddItem(str);
		}
		return true;
	}

	return false;
}

function bool GetCollectionName(name PropertyName, string str_index, out string out_value)
{
	local int index, i;
	index = CollectionsIdStr.Find('Option', PropertyName);
	if (index != INDEX_NONE)
	{
		i = int(str_index);
		if (i >= INDEX_NONE && i < CollectionsIdStr[index].Names.Length)
		{
			out_value = CollectionsIdStr[index].Names[i];
			return true;
		}			
	}

	return false;
}

function bool GetCollectionIndexValue(name PropertyName, string str_index, out string out_value)
{
	local int index, i;
	index = CollectionsIdStr.Find('Option', PropertyName);
	if (index != INDEX_NONE)
	{
		i = CollectionsIdStr[index].Ids.Find(int(str_index));
		if (i != INDEX_NONE)
		{
			out_value = CollectionsIdStr[index].Names[i];
			return true;
		}				
	}

	return false;
}

function bool GetCollectionIndexId(name PropertyName, string value, out string out_id)
{
	local int index, i;
	index = CollectionsIdStr.Find('Option', PropertyName);
	if (index != INDEX_NONE)
	{
		i = CollectionsIdStr[index].Names.Find(value);
		if (i != INDEX_NONE)
		{
			out_id = ""$CollectionsIdStr[index].Ids[i];
			return true;
		}				
	}

	return false;
}

//**********************************************************************************
// Private functions
//**********************************************************************************

function ResetToDefaults()
{
	`Log(name$"::ResetToDefaults",,'BotBalancer');

	ConfigClass.static.Localize("WebAdmin_ResetToDefaults", "", "");
	ConfigClass.static.StaticSaveConfig();
}

function string CreateDataStoreStringList(name listname, array<string> entries)
{
	local DataStoreClient DSC;
	local string fieldstr, ret;
	local name fieldname;
	local int i;

	// Get a reference to (or create) a 2D string list data store
	DSC = Class'UIInteraction'.static.GetDataStoreClient();

	if (StringDatastore == none)
	{
		StringDatastore = UTUIDataStore_2DStringList(DSC.FindDataStore(StringDatastoreClass.default.Tag));
		if (StringDatastore == none)
		{
			StringDatastore = DSC.CreateDataStore(StringDatastoreClass);
			DSC.RegisterDataStore(StringDatastore);
		}
	}

	fieldstr = DataFieldPrefix$listname;
	fieldname = name(fieldstr);
	// Setup and fill the data fields within the data store (if they are not already set)
	if (StringDatastore.GetFieldIndex(fieldname) == INDEX_None)
	{
		i = StringDataStore.AddField(fieldname);
		StringDatastore.AddFieldList(i, listname);
		StringDataStore.UpdateFieldList(i, listname, entries);

		RegisteredDatafields.AddItem(fieldname);
	}

	ret = "<"$StringDatastore.Tag$":"$fieldname$">";
	return ret;
}

// Handles finding and casting generated option controls
static final function UICheckbox FindOptionCheckBoxByName(UTUIOptionList List, name OptionName)
{
	local int i;

	i = List.GetObjectInfoIndexFromName(OptionName);

	if (i != INDEX_None)
		return UICheckbox(List.GeneratedObjects[i].OptionObj);

	return None;
}

// Handles finding generated option controls
static final function bool FindOptionObjectByName(UTUIOptionList List, name OptionName, out UIObject obj)
{
	local int i;

	i = List.GetObjectInfoIndexFromName(OptionName);

	if (i != INDEX_None)
		obj = List.GeneratedObjects[i].OptionObj;
	else
		obj = none;

	return (obj != none);
}

static final function bool GetOptionObjectValue(UIObject obj, out string value)
{
	local UICheckbox CurCheckBox;
	local UIEditBox CurEditBox;
	local UINumericEditBox CurNumEditBox;
	local UIComboBox CurComboBox;
	//local UISlider CurSlider;
	local bool boolvalue;
	local float floatvalue;
	
	CurCheckBox = UICheckbox(obj);
	if (CurCheckBox != none)
	{
		boolvalue = CurCheckBox.IsChecked();
		value = string(int(boolvalue));
			
		return true;
	}

	CurNumEditBox = UINumericEditBox(obj);
	if (CurNumEditBox != none)
	{
		//floatvalue = CurNumEditBox.GetNumericValue();
		floatvalue = float(CurNumEditBox.GetValue(true));

		value = string(floatvalue);
		
		return true;
	}

	CurEditBox = UIEditBox(obj);
	if (CurEditBox != none)
	{
		value = CurEditBox.GetValue(true);
		
		return true;
	}

	CurComboBox = UIComboBox(obj);
	if (CurComboBox != none)
	{
		value = CurComboBox.ComboEditbox.GetValue(true);
		
		return true;
	}

	//CurSlider = UISlider(obj);
	//if (CurSlider != none)
	//{
	//	value = string(CurSlider.GetValue());
		
	//	return true;
	//}

	return false;
}

static final function bool SetOptionObjectValue(UIObject obj, string value, optional string markupstring)
{
	local UICheckbox CurCheckBox;
	local UIEditBox CurEditBox;
	local UINumericEditBox CurNumEditBox;
	local UIComboBox CurComboBox;
	//local UISlider CurSlider;
	local bool boolvalue;
	local float floatvalue;
	local int index;
	
	CurCheckBox = UICheckbox(obj);
	if (CurCheckBox != none)
	{
		boolvalue = bool(value);
		CurCheckBox.SetValue(boolvalue);

		return true;
	}

	CurNumEditBox = UINumericEditBox(obj);
	if (CurNumEditBox != none)
	{
		floatvalue = ParseFloat(value);
		CurNumEditBox.SetNumericValue(floatvalue, true);
		return true;
	}

	CurEditBox = UIEditBox(obj);
	if (CurEditBox != none)
	{
		CurEditBox.SetDataStoreBinding(value);
		return true;
	}

	CurComboBox = UIComboBox(obj);
	if (CurComboBox != none)
	{
		index = CurComboBox.ComboList.FindItemIndex(value);
		if (index != INDEX_NONE)
		{
			CurComboBox.ComboEditbox.SetDataStoreBinding(value);
			CurComboBox.ComboList.SetIndex(index);
		}
		//index = int(value);
		//if (index < arrstring.Length)
		//{
		//	//CurComboBox.ComboEditbox.SetDataStoreBinding(arrstring[index]);
		//	//CurComboBox.ComboList.SetIndex(index);
		//}
		return true;
	}

	//CurSlider = UISlider(obj);
	//if (CurSlider != none)
	//{
	//	CurSlider.SetValue(value);
	//}

	return false;
}

static function float ParseFloat(string value)
{
	if (InStr(value, ",", false) != INDEX_NONE)
	{
		value = Repl(value, ",", "."); 
	}

	return float(value);
}

defaultproperties
{
	Title="Configure BotBalancer"

	SettingsClass=class'BotBalancerMutatorSettings'
	ConfigClass=class'BotBalancerMutator'

	StringDatastoreClass=class'UTUIDataStore_2DStringList'
	DataFieldPrefix="BotBalancer_"
}
